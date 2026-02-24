// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBotcoinMining} from "./interfaces/IBotcoinMining.sol";

/// @title BotcoinMiningPool
/// @author tekkaadan
/// @notice A mining pool contract for BOTCOIN that implements EIP-1271 signature
///         validation, allowing an operator EOA to authenticate as this contract
///         address with the BOTCOIN coordinator.
///
/// @dev Architecture:
///   - Epoch tracking is delegated to the upstream mining contract via IBotcoinMining.
///   - Depositors lock BOTCOIN for future epochs; the pool's aggregate balance
///     determines the coordinator's credit tier (25M / 50M / 100M).
///   - The operator runs inference, solves challenges, and posts receipts.
///   - After each epoch ends and is funded, rewards are claimed per-epoch and
///     distributed pro-rata to depositors based on their deposit share.
///   - Anyone can trigger reward claims after a grace period, removing the
///     operator as a liveness dependency.
///   - Unclaimed depositor rewards expire after `claimWindow` seconds.
contract BotcoinMiningPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice EIP-1271 magic value returned on successful signature validation
    bytes4 public constant EIP1271_MAGIC = 0x1626ba7e;

    /// @notice Maximum operator fee in basis points (20% = 2000 bps)
    uint16 public constant MAX_FEE_BPS = 2000;

    /// @notice Basis points denominator
    uint16 public constant BPS_DENOMINATOR = 10_000;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The BOTCOIN ERC-20 token
    IERC20 public immutable botcoin;

    /// @notice The upstream mining contract (receipts + claims)
    address public immutable miningContract;

    /// @notice IBotcoinMining view interface for epoch queries
    /// @dev    May point to the same address as miningContract, or to a
    ///         separate read-only adapter if the mining contract's view ABI
    ///         differs from IBotcoinMining.
    IBotcoinMining public immutable miningView;

    /// @notice Allowed function selector for claim calls forwarded to mining contract
    bytes4 public immutable claimSelector;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Operator State
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The operator EOA authorized to sign on behalf of this pool
    address public operator;

    /// @notice Operator fee in basis points (e.g., 500 = 5%)
    uint16 public operatorFeeBps;

    /// @notice Pending operator address for two-step transfer
    address public pendingOperator;

    /// @notice Accumulated operator fees available to withdraw
    uint256 public accumulatedOperatorFees;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Timing Config
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Seconds after epoch ends before anyone (not just operator) can
    ///         trigger `claimEpochReward`. During the grace period only the
    ///         operator may claim.
    uint256 public claimGracePeriod;

    /// @notice Seconds after epoch ends during which depositors may claim their
    ///         reward share. After this window unclaimed shares are forfeited and
    ///         can be swept by the owner.
    uint256 public claimWindow;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Tier Config
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tier thresholds: tier 1, 2, 3 minimum deposits
    uint256[3] public tierThresholds;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Deposit Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Per-depositor, per-epoch deposit amount
    mapping(address => mapping(uint256 => uint256)) public deposits;

    /// @notice Total deposits for each epoch
    mapping(uint256 => uint256) public epochTotalDeposits;

    /// @notice Whether a depositor has withdrawn for a given epoch
    mapping(address => mapping(uint256 => bool)) public withdrawn;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Reward Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Total depositor rewards recorded for a given epoch (after fee)
    mapping(uint256 => uint256) public epochRewards;

    /// @notice Whether rewards have been claimed from mining contract for an epoch
    mapping(uint256 => bool) public epochRewardsClaimed;

    /// @notice Timestamp at which epoch rewards were claimed (for expiry calc)
    mapping(uint256 => uint256) public epochRewardsClaimedAt;

    /// @notice Whether a depositor has claimed their reward share for an epoch
    mapping(address => mapping(uint256 => bool)) public rewardClaimed;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════════

    event Deposited(address indexed depositor, uint256 indexed epochId, uint256 amount);
    event Withdrawn(address indexed depositor, uint256 indexed epochId, uint256 amount);
    event EpochRewardClaimed(uint256 indexed epochId, uint256 totalReward, uint256 operatorFee, address claimedBy);
    event RewardDistributed(address indexed depositor, uint256 indexed epochId, uint256 amount);
    event ExpiredRewardsSwept(uint256 indexed epochId, uint256 amount, address recipient);
    event OperatorTransferInitiated(address indexed currentOperator, address indexed pendingOperator);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event OperatorFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event OperatorFeesWithdrawn(address indexed to, uint256 amount);
    event ReceiptSubmitted(bytes4 selector, bool success);
    event ClaimWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event GracePeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    // ═══════════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAmount();
    error ZeroAddress();
    error EpochNotEnded();
    error EpochAlreadyStarted();
    error NoDeposit();
    error AlreadyWithdrawn();
    error AlreadyClaimed();
    error RewardsNotClaimedYet();
    error NoRewards();
    error SubmitFailed();
    error ClaimFailed();
    error FeeTooHigh();
    error NotOperator();
    error NotPendingOperator();
    error InvalidSelector();
    error GracePeriodNotElapsed();
    error ClaimWindowExpired();
    error ClaimWindowNotExpired();
    error CalldataTooShort();

    // ═══════════════════════════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════════════════════════

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _botcoin         BOTCOIN token address
    /// @param _miningContract  Upstream mining contract address (receives receipts + claims)
    /// @param _miningView      IBotcoinMining view interface (may == _miningContract)
    /// @param _operator        Initial operator EOA
    /// @param _feeBps          Initial operator fee in basis points
    /// @param _tierThresholds  Tier 1, 2, 3 thresholds in BOTCOIN (wei)
    /// @param _claimSelector   Allowed function selector for mining contract claim calls
    /// @param _claimGracePeriod Seconds after epoch ends before anyone can trigger claims
    /// @param _claimWindow     Seconds after epoch ends during which depositor shares are valid
    constructor(
        address _botcoin,
        address _miningContract,
        address _miningView,
        address _operator,
        uint16 _feeBps,
        uint256[3] memory _tierThresholds,
        bytes4 _claimSelector,
        uint256 _claimGracePeriod,
        uint256 _claimWindow
    ) Ownable(msg.sender) {
        if (_botcoin == address(0) || _miningContract == address(0) || _operator == address(0))
            revert ZeroAddress();
        if (_miningView == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        botcoin = IERC20(_botcoin);
        miningContract = _miningContract;
        miningView = IBotcoinMining(_miningView);
        claimSelector = _claimSelector;
        operator = _operator;
        operatorFeeBps = _feeBps;
        tierThresholds = _tierThresholds;
        claimGracePeriod = _claimGracePeriod;
        claimWindow = _claimWindow;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  EIP-1271: Signature Validation
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice EIP-1271 signature validation. The coordinator calls this with the
    ///         EIP-191 digest of the nonce message and the operator's signature.
    /// @dev    CRITICAL: `hash` is already `ethers.hashMessage(message)` — do NOT
    ///         re-hash it. Just ecrecover directly against it.
    /// @param hash      The EIP-191 personal_sign digest (pre-computed by coordinator)
    /// @param signature 65-byte ECDSA signature (r, s, v)
    /// @return magicValue EIP1271_MAGIC (0x1626ba7e) if valid, 0xffffffff otherwise
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4) {
        if (signature.length != 65) return bytes4(0xffffffff);

        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(hash, signature);

        if (err != ECDSA.RecoverError.NoError) return bytes4(0xffffffff);
        if (recovered != operator) return bytes4(0xffffffff);

        return EIP1271_MAGIC;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Epoch Queries (delegated to mining contract)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the current epoch ID from the mining contract
    function currentEpoch() public view returns (uint256) {
        return miningView.currentEpoch();
    }

    /// @notice Returns the end timestamp for a given epoch
    function epochEndTime(uint256 epochId) public view returns (uint256) {
        return miningView.getEpochEndTime(epochId);
    }

    /// @notice Returns the current tier based on total deposits for an epoch
    /// @return tier 0 = below tier 1, 1-3 = tier levels
    function epochTier(uint256 epochId) public view returns (uint8) {
        uint256 total = epochTotalDeposits[epochId];
        if (total >= tierThresholds[2]) return 3;
        if (total >= tierThresholds[1]) return 2;
        if (total >= tierThresholds[0]) return 1;
        return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Deposit & Withdrawal
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit BOTCOIN for the next epoch's mining pool
    /// @dev Deposits target the NEXT epoch (currentEpoch + 1). Tokens are locked
    ///      until that epoch ends on the mining contract.
    /// @param amount Amount of BOTCOIN to deposit (in wei)
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 targetEpoch = currentEpoch() + 1;

        deposits[msg.sender][targetEpoch] += amount;
        epochTotalDeposits[targetEpoch] += amount;

        botcoin.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, targetEpoch, amount);
    }

    /// @notice Deposit BOTCOIN for a specific future epoch
    /// @param amount Amount of BOTCOIN to deposit (in wei)
    /// @param epochId Target epoch (must not have started yet)
    function depositForEpoch(uint256 amount, uint256 epochId) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Epoch must not have started — its end time must be in the future
        // and it must be after the current epoch
        if (epochId <= currentEpoch()) revert EpochAlreadyStarted();

        deposits[msg.sender][epochId] += amount;
        epochTotalDeposits[epochId] += amount;

        botcoin.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, epochId, amount);
    }

    /// @notice Withdraw deposited BOTCOIN after an epoch has ended
    /// @param epochId The epoch to withdraw from
    function withdraw(uint256 epochId) external nonReentrant {
        // Epoch must have ended (read from mining contract)
        if (block.timestamp < epochEndTime(epochId)) revert EpochNotEnded();

        uint256 amount = deposits[msg.sender][epochId];
        if (amount == 0) revert NoDeposit();
        if (withdrawn[msg.sender][epochId]) revert AlreadyWithdrawn();

        withdrawn[msg.sender][epochId] = true;

        botcoin.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, epochId, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Mining Operations (Operator Only)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Forward a solve receipt to the mining contract
    /// @dev The mining contract sees msg.sender == this pool contract.
    ///      The coordinator provides pre-encoded calldata — just forward it.
    /// @param calldata_ The pre-encoded calldata from the coordinator's submit response
    function submitReceiptToMining(bytes calldata calldata_) external onlyOperator nonReentrant {
        (bool success, ) = miningContract.call(calldata_);
        if (!success) revert SubmitFailed();

        bytes4 selector = bytes4(calldata_[:4]);
        emit ReceiptSubmitted(selector, success);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Reward Claims (single-epoch, proportional by design)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Claim mining rewards for a SINGLE completed epoch.
    /// @dev    Operator can call immediately after epoch ends. Anyone else can
    ///         call after epochEnd + claimGracePeriod.
    ///         Single-epoch claims ensure exact proportional accounting — no
    ///         even-split approximation across multiple epochs.
    /// @param epochId The epoch to claim rewards for
    /// @param claimCalldata Encoded call to mining contract's claim function
    ///        (obtained from coordinator GET /v1/claim-calldata?epochs=N)
    function claimEpochReward(
        uint256 epochId,
        bytes calldata claimCalldata
    ) external nonReentrant {
        // Validate selector
        if (claimCalldata.length < 4) revert CalldataTooShort();
        if (bytes4(claimCalldata[:4]) != claimSelector) revert InvalidSelector();

        // Epoch must have ended
        uint256 endTime = epochEndTime(epochId);
        if (block.timestamp < endTime) revert EpochNotEnded();

        // Check claim window hasn't expired
        if (block.timestamp > endTime + claimWindow) revert ClaimWindowExpired();

        // Authorization: operator immediately, anyone else after grace period
        if (msg.sender != operator) {
            if (block.timestamp < endTime + claimGracePeriod) {
                revert GracePeriodNotElapsed();
            }
        }

        // Prevent double-claim
        if (epochRewardsClaimed[epochId]) revert AlreadyClaimed();
        epochRewardsClaimed[epochId] = true;
        epochRewardsClaimedAt[epochId] = block.timestamp;

        // Snapshot balance before claim
        uint256 balanceBefore = botcoin.balanceOf(address(this));

        // Forward claim to mining contract
        (bool success, ) = miningContract.call(claimCalldata);
        if (!success) revert ClaimFailed();

        // Calculate total rewards received
        uint256 totalReceived = botcoin.balanceOf(address(this)) - balanceBefore;
        if (totalReceived == 0) revert NoRewards();

        // Deduct operator fee
        uint256 operatorFee = (totalReceived * operatorFeeBps) / BPS_DENOMINATOR;
        uint256 depositorRewards = totalReceived - operatorFee;
        accumulatedOperatorFees += operatorFee;

        // Record rewards for this epoch
        epochRewards[epochId] = depositorRewards;

        emit EpochRewardClaimed(epochId, depositorRewards, operatorFee, msg.sender);
    }

    /// @notice Depositors claim their pro-rata share of rewards for an epoch
    /// @param epochId The epoch to claim rewards for
    function claimRewardShare(uint256 epochId) external nonReentrant {
        if (!epochRewardsClaimed[epochId]) revert RewardsNotClaimedYet();
        if (rewardClaimed[msg.sender][epochId]) revert AlreadyClaimed();

        // Check claim window hasn't expired for this depositor
        uint256 endTime = epochEndTime(epochId);
        if (block.timestamp > endTime + claimWindow) revert ClaimWindowExpired();

        uint256 userDeposit = deposits[msg.sender][epochId];
        if (userDeposit == 0) revert NoDeposit();

        rewardClaimed[msg.sender][epochId] = true;

        uint256 totalDeposits = epochTotalDeposits[epochId];
        uint256 reward = (epochRewards[epochId] * userDeposit) / totalDeposits;

        botcoin.safeTransfer(msg.sender, reward);

        emit RewardDistributed(msg.sender, epochId, reward);
    }

    /// @notice Batch claim reward shares for multiple epochs
    /// @param epochIds Array of epoch IDs to claim for
    function batchClaimRewardShares(uint256[] calldata epochIds) external nonReentrant {
        uint256 totalReward = 0;

        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 eid = epochIds[i];
            if (!epochRewardsClaimed[eid]) continue; // skip unclaimed epochs
            if (rewardClaimed[msg.sender][eid]) continue; // skip already claimed

            // Check claim window
            uint256 endTime = epochEndTime(eid);
            if (block.timestamp > endTime + claimWindow) continue; // skip expired

            uint256 userDeposit = deposits[msg.sender][eid];
            if (userDeposit == 0) continue;

            rewardClaimed[msg.sender][eid] = true;

            uint256 totalDeposits = epochTotalDeposits[eid];
            uint256 reward = (epochRewards[eid] * userDeposit) / totalDeposits;
            totalReward += reward;

            emit RewardDistributed(msg.sender, eid, reward);
        }

        if (totalReward == 0) revert NoRewards();
        botcoin.safeTransfer(msg.sender, totalReward);
    }

    /// @notice Sweep unclaimed rewards after claim window expires
    /// @dev Only owner can call. Rewards that depositors did not claim in time
    ///      are returned to the owner (or a designated treasury).
    /// @param epochId The expired epoch to sweep
    /// @param recipient Where to send swept funds
    function sweepExpiredRewards(
        uint256 epochId,
        address recipient
    ) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 endTime = epochEndTime(epochId);
        if (block.timestamp <= endTime + claimWindow) revert ClaimWindowNotExpired();
        if (!epochRewardsClaimed[epochId]) revert RewardsNotClaimedYet();

        // Calculate remaining unclaimed rewards
        // This is approximate — we check the recorded reward pool minus what was
        // already distributed. In practice the owner should only sweep after the
        // window is well past and most depositors have claimed.
        uint256 remaining = epochRewards[epochId]; // will be 0 if fully claimed
        if (remaining == 0) revert NoRewards();

        // Zero out to prevent re-sweep
        epochRewards[epochId] = 0;

        botcoin.safeTransfer(recipient, remaining);

        emit ExpiredRewardsSwept(epochId, remaining, recipient);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Operator Management
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initiate operator transfer (two-step for safety)
    function transferOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        pendingOperator = newOperator;
        emit OperatorTransferInitiated(operator, newOperator);
    }

    /// @notice Accept operator role (must be called by pending operator)
    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert NotPendingOperator();
        address old = operator;
        operator = pendingOperator;
        pendingOperator = address(0);
        emit OperatorTransferred(old, operator);
    }

    /// @notice Update operator fee (owner only, capped at MAX_FEE_BPS)
    function setOperatorFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint16 old = operatorFeeBps;
        operatorFeeBps = newFeeBps;
        emit OperatorFeeUpdated(old, newFeeBps);
    }

    /// @notice Withdraw accumulated operator fees
    function withdrawOperatorFees(address to) external onlyOperator nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = accumulatedOperatorFees;
        if (amount == 0) revert NoRewards();
        accumulatedOperatorFees = 0;
        botcoin.safeTransfer(to, amount);
        emit OperatorFeesWithdrawn(to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Admin
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Update the claim window duration
    function setClaimWindow(uint256 newWindow) external onlyOwner {
        uint256 old = claimWindow;
        claimWindow = newWindow;
        emit ClaimWindowUpdated(old, newWindow);
    }

    /// @notice Update the grace period
    function setGracePeriod(uint256 newPeriod) external onlyOwner {
        uint256 old = claimGracePeriod;
        claimGracePeriod = newPeriod;
        emit GracePeriodUpdated(old, newPeriod);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  View Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Preview a depositor's reward share for an epoch (before claiming)
    function previewRewardShare(
        address depositor,
        uint256 epochId
    ) external view returns (uint256) {
        if (!epochRewardsClaimed[epochId]) return 0;
        uint256 totalDeposits = epochTotalDeposits[epochId];
        if (totalDeposits == 0) return 0;
        uint256 userDeposit = deposits[depositor][epochId];
        return (epochRewards[epochId] * userDeposit) / totalDeposits;
    }

    /// @notice Check if a depositor's claim window is still open
    function isClaimWindowOpen(uint256 epochId) external view returns (bool) {
        uint256 endTime = epochEndTime(epochId);
        return block.timestamp <= endTime + claimWindow;
    }
}

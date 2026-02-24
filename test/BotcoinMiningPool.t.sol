// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BotcoinMiningPool} from "../src/BotcoinMiningPool.sol";
import {MockBotcoin} from "./mocks/MockBotcoin.sol";
import {MockMiningContract} from "./mocks/MockMiningContract.sol";

contract BotcoinMiningPoolTest is Test {
    BotcoinMiningPool pool;
    MockBotcoin botcoin;
    MockMiningContract mining;

    address owner = address(this);
    uint256 operatorPk = 0xA11CE;
    address operator = vm.addr(operatorPk);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    bytes4 constant CLAIM_SELECTOR = bytes4(keccak256("claim(uint256[])"));
    bytes4 constant EIP1271_MAGIC = 0x1626ba7e;

    uint256 constant TIER1 = 25_000_000 ether;
    uint256 constant TIER2 = 50_000_000 ether;
    uint256 constant TIER3 = 100_000_000 ether;

    uint256 constant GRACE_PERIOD = 1 hours;
    uint256 constant CLAIM_WINDOW = 7 days;

    function setUp() public {
        botcoin = new MockBotcoin();
        mining = new MockMiningContract();

        // Configure mining contract
        mining.setRewardToken(address(botcoin));
        mining.setCurrentEpoch(5);
        // Epochs 1-5 end times (each 24h apart starting at timestamp 100_000)
        for (uint256 i = 1; i <= 10; i++) {
            mining.setEpochEndTime(i, 100_000 + (i * 86_400));
        }

        pool = new BotcoinMiningPool(
            address(botcoin),
            address(mining),
            address(mining),      // miningView == miningContract
            operator,
            500,                   // 5% fee
            [TIER1, TIER2, TIER3],
            CLAIM_SELECTOR,
            GRACE_PERIOD,
            CLAIM_WINDOW
        );

        // Fund test accounts
        botcoin.mint(alice, 200_000_000 ether);
        botcoin.mint(bob, 200_000_000 ether);
        botcoin.mint(carol, 200_000_000 ether);

        // Approvals
        vm.prank(alice);
        botcoin.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        botcoin.approve(address(pool), type(uint256).max);
        vm.prank(carol);
        botcoin.approve(address(pool), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Epoch Delegation
    // ═══════════════════════════════════════════════════════════════════════

    function test_currentEpoch_readsFromMining() public view {
        assertEq(pool.currentEpoch(), 5);
    }

    function test_epochEndTime_readsFromMining() public view {
        assertEq(pool.epochEndTime(3), 100_000 + (3 * 86_400));
    }

    function test_currentEpoch_updatesWhenMiningAdvances() public {
        mining.setCurrentEpoch(10);
        assertEq(pool.currentEpoch(), 10);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Deposit
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_basic() public {
        vm.prank(alice);
        pool.deposit(TIER1);

        // Should target epoch 6 (current + 1)
        assertEq(pool.deposits(alice, 6), TIER1);
        assertEq(pool.epochTotalDeposits(6), TIER1);
        assertEq(botcoin.balanceOf(address(pool)), TIER1);
    }

    function test_deposit_multipleDepositors() public {
        vm.prank(alice);
        pool.deposit(TIER1);
        vm.prank(bob);
        pool.deposit(TIER2);

        assertEq(pool.epochTotalDeposits(6), TIER1 + TIER2);
    }

    function test_deposit_additiveForSameUser() public {
        vm.prank(alice);
        pool.deposit(TIER1);
        vm.prank(alice);
        pool.deposit(TIER1);

        assertEq(pool.deposits(alice, 6), TIER1 * 2);
    }

    function test_deposit_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.ZeroAmount.selector);
        pool.deposit(0);
    }

    function test_depositForEpoch_futureEpoch() public {
        vm.prank(alice);
        pool.depositForEpoch(TIER1, 8);

        assertEq(pool.deposits(alice, 8), TIER1);
        assertEq(pool.epochTotalDeposits(8), TIER1);
    }

    function test_depositForEpoch_revertsIfCurrentOrPast() public {
        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.EpochAlreadyStarted.selector);
        pool.depositForEpoch(TIER1, 5); // current epoch

        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.EpochAlreadyStarted.selector);
        pool.depositForEpoch(TIER1, 3); // past epoch
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Withdrawal
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_afterEpochEnds() public {
        // Deposit for epoch 6
        vm.prank(alice);
        pool.deposit(TIER1);

        // Advance time past epoch 6 end
        uint256 epoch6End = pool.epochEndTime(6);
        vm.warp(epoch6End + 1);

        uint256 balBefore = botcoin.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw(6);

        assertEq(botcoin.balanceOf(alice), balBefore + TIER1);
        assertTrue(pool.withdrawn(alice, 6));
    }

    function test_withdraw_revertsDuringActiveEpoch() public {
        vm.prank(alice);
        pool.deposit(TIER1);

        // Warp to within epoch 6 (before end)
        vm.warp(pool.epochEndTime(6) - 1);

        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.EpochNotEnded.selector);
        pool.withdraw(6);
    }

    function test_withdraw_revertsDoubleWithdraw() public {
        vm.prank(alice);
        pool.deposit(TIER1);

        vm.warp(pool.epochEndTime(6) + 1);

        vm.prank(alice);
        pool.withdraw(6);

        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.AlreadyWithdrawn.selector);
        pool.withdraw(6);
    }

    function test_withdraw_revertsNoDeposit() public {
        vm.warp(pool.epochEndTime(6) + 1);

        vm.prank(bob);
        vm.expectRevert(BotcoinMiningPool.NoDeposit.selector);
        pool.withdraw(6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Tier Thresholds
    // ═══════════════════════════════════════════════════════════════════════

    function test_tier_belowMinimum() public view {
        assertEq(pool.epochTier(6), 0); // no deposits yet
    }

    function test_tier1() public {
        vm.prank(alice);
        pool.deposit(TIER1);
        assertEq(pool.epochTier(6), 1);
    }

    function test_tier2() public {
        vm.prank(alice);
        pool.deposit(TIER2);
        assertEq(pool.epochTier(6), 2);
    }

    function test_tier3() public {
        vm.prank(alice);
        pool.deposit(TIER3);
        assertEq(pool.epochTier(6), 3);
    }

    function test_tier_aggregatesMultipleDepositors() public {
        // Alice + Bob together reach tier 2
        vm.prank(alice);
        pool.deposit(TIER1); // 25M
        vm.prank(bob);
        pool.deposit(TIER1); // +25M = 50M total
        assertEq(pool.epochTier(6), 2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  EIP-1271 Signature Validation
    // ═══════════════════════════════════════════════════════════════════════

    function test_eip1271_validSignature() public view {
        // Simulate coordinator flow: hash a nonce message via EIP-191
        bytes32 msgHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n5", "nonce"
        ));

        // Operator signs the pre-hashed digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, msgHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Pool verifies — hash is already EIP-191 prefixed
        bytes4 result = pool.isValidSignature(msgHash, sig);
        assertEq(result, EIP1271_MAGIC);
    }

    function test_eip1271_invalidSigner() public {
        bytes32 msgHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n5", "nonce"
        ));

        // Sign with a random key (not operator)
        uint256 randomPk = 0xBADBAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomPk, msgHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes4 result = pool.isValidSignature(msgHash, sig);
        assertEq(result, bytes4(0xffffffff));
    }

    function test_eip1271_wrongSignatureLength() public view {
        bytes32 msgHash = keccak256("test");
        bytes memory shortSig = new bytes(64); // too short

        bytes4 result = pool.isValidSignature(msgHash, shortSig);
        assertEq(result, bytes4(0xffffffff));
    }

    function test_eip1271_emptySignature() public view {
        bytes32 msgHash = keccak256("test");
        bytes memory empty = "";

        bytes4 result = pool.isValidSignature(msgHash, empty);
        assertEq(result, bytes4(0xffffffff));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Receipt Submission
    // ═══════════════════════════════════════════════════════════════════════

    function test_submitReceipt_operatorOnly() public {
        bytes memory fakeCalldata = abi.encodeWithSignature("submitReceipt(bytes)", hex"1234");

        vm.prank(operator);
        pool.submitReceiptToMining(fakeCalldata);

        // Should have forwarded to mining contract
        assertGt(mining.lastReceiptCalldata().length, 0);
    }

    function test_submitReceipt_revertsNonOperator() public {
        bytes memory fakeCalldata = abi.encodeWithSignature("submitReceipt(bytes)", hex"1234");

        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.NotOperator.selector);
        pool.submitReceiptToMining(fakeCalldata);
    }

    function test_submitReceipt_revertsOnFailure() public {
        mining.setReceiptAccepted(false);

        bytes memory fakeCalldata = abi.encodeWithSignature("submitReceipt(bytes)", hex"1234");

        vm.prank(operator);
        vm.expectRevert(BotcoinMiningPool.SubmitFailed.selector);
        pool.submitReceiptToMining(fakeCalldata);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Reward Claims
    // ═══════════════════════════════════════════════════════════════════════

    function _setupEpoch3WithDeposits() internal {
        // Set epoch to 2 so deposits target epoch 3
        mining.setCurrentEpoch(2);

        vm.prank(alice);
        pool.deposit(60_000_000 ether); // 60%
        vm.prank(bob);
        pool.deposit(40_000_000 ether); // 40%

        // Advance to after epoch 3 ends
        mining.setCurrentEpoch(5);
        vm.warp(pool.epochEndTime(3) + 1);

        // Fund the mock mining contract with reward tokens
        botcoin.mint(address(mining), 1000 ether);
        mining.setNextClaimPayout(1000 ether);
    }

    function _claimCalldata(uint256 epochId) internal pure returns (bytes memory) {
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epochId;
        return abi.encodeWithSelector(CLAIM_SELECTOR, epochs);
    }

    function test_claimEpochReward_operatorImmediate() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        assertTrue(pool.epochRewardsClaimed(3));
        // 1000 ether total, 5% fee = 50 ether, 950 ether to depositors
        assertEq(pool.epochRewards(3), 950 ether);
        assertEq(pool.accumulatedOperatorFees(), 50 ether);
    }

    function test_claimEpochReward_anyoneAfterGrace() public {
        _setupEpoch3WithDeposits();

        // Carol (random person) tries before grace period
        vm.prank(carol);
        vm.expectRevert(BotcoinMiningPool.GracePeriodNotElapsed.selector);
        pool.claimEpochReward(3, _claimCalldata(3));

        // Advance past grace period
        vm.warp(pool.epochEndTime(3) + GRACE_PERIOD + 1);

        // Now carol can claim
        vm.prank(carol);
        pool.claimEpochReward(3, _claimCalldata(3));

        assertTrue(pool.epochRewardsClaimed(3));
    }

    function test_claimEpochReward_revertsInvalidSelector() public {
        _setupEpoch3WithDeposits();

        // Use wrong selector
        bytes memory badCalldata = abi.encodeWithSignature("steal(uint256)", 3);

        vm.prank(operator);
        vm.expectRevert(BotcoinMiningPool.InvalidSelector.selector);
        pool.claimEpochReward(3, badCalldata);
    }

    function test_claimEpochReward_revertsCalldataTooShort() public {
        _setupEpoch3WithDeposits();

        bytes memory shortCalldata = hex"aabb";

        vm.prank(operator);
        vm.expectRevert(BotcoinMiningPool.CalldataTooShort.selector);
        pool.claimEpochReward(3, shortCalldata);
    }

    function test_claimEpochReward_revertsBeforeEpochEnds() public {
        mining.setCurrentEpoch(2);
        vm.prank(alice);
        pool.deposit(TIER1);

        // Don't advance time — still in epoch 3 window
        mining.setCurrentEpoch(3);
        vm.warp(pool.epochEndTime(3) - 100);

        vm.prank(operator);
        vm.expectRevert(BotcoinMiningPool.EpochNotEnded.selector);
        pool.claimEpochReward(3, _claimCalldata(3));
    }

    function test_claimEpochReward_revertsDoubleClaim() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        // Second claim
        botcoin.mint(address(mining), 500 ether);
        mining.setNextClaimPayout(500 ether);

        vm.prank(operator);
        vm.expectRevert(BotcoinMiningPool.AlreadyClaimed.selector);
        pool.claimEpochReward(3, _claimCalldata(3));
    }

    function test_claimEpochReward_revertsAfterClaimWindowExpires() public {
        _setupEpoch3WithDeposits();

        // Warp past claim window
        vm.warp(pool.epochEndTime(3) + CLAIM_WINDOW + 1);

        vm.prank(operator);
        vm.expectRevert(BotcoinMiningPool.ClaimWindowExpired.selector);
        pool.claimEpochReward(3, _claimCalldata(3));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Pro-Rata Reward Distribution
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimRewardShare_proRata() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        // Alice: 60% of 950 = 570
        uint256 aliceBefore = botcoin.balanceOf(alice);
        vm.prank(alice);
        pool.claimRewardShare(3);
        uint256 aliceReward = botcoin.balanceOf(alice) - aliceBefore;
        assertEq(aliceReward, 570 ether);

        // Bob: 40% of 950 = 380
        uint256 bobBefore = botcoin.balanceOf(bob);
        vm.prank(bob);
        pool.claimRewardShare(3);
        uint256 bobReward = botcoin.balanceOf(bob) - bobBefore;
        assertEq(bobReward, 380 ether);
    }

    function test_claimRewardShare_revertsBeforeEpochClaimed() public {
        _setupEpoch3WithDeposits();

        // Don't claim epoch reward first
        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.RewardsNotClaimedYet.selector);
        pool.claimRewardShare(3);
    }

    function test_claimRewardShare_revertsDoubleClaim() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        vm.prank(alice);
        pool.claimRewardShare(3);

        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.AlreadyClaimed.selector);
        pool.claimRewardShare(3);
    }

    function test_claimRewardShare_revertsNoDeposit() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        vm.prank(carol); // carol didn't deposit
        vm.expectRevert(BotcoinMiningPool.NoDeposit.selector);
        pool.claimRewardShare(3);
    }

    function test_claimRewardShare_revertsAfterClaimWindow() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        // Warp past claim window
        vm.warp(pool.epochEndTime(3) + CLAIM_WINDOW + 1);

        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.ClaimWindowExpired.selector);
        pool.claimRewardShare(3);
    }

    function test_batchClaimRewardShares() public {
        // Set up two epochs with deposits
        mining.setCurrentEpoch(2);
        vm.prank(alice);
        pool.deposit(100_000_000 ether); // epoch 3

        mining.setCurrentEpoch(3);
        vm.prank(alice);
        pool.deposit(100_000_000 ether); // epoch 4

        // End both epochs
        mining.setCurrentEpoch(6);
        vm.warp(pool.epochEndTime(4) + 1);

        // Claim epoch 3 rewards
        botcoin.mint(address(mining), 500 ether);
        mining.setNextClaimPayout(500 ether);
        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        // Claim epoch 4 rewards
        botcoin.mint(address(mining), 300 ether);
        mining.setNextClaimPayout(300 ether);
        vm.prank(operator);
        pool.claimEpochReward(4, _claimCalldata(4));

        // Alice batch claims both
        uint256 aliceBefore = botcoin.balanceOf(alice);
        uint256[] memory epochs = new uint256[](2);
        epochs[0] = 3;
        epochs[1] = 4;
        vm.prank(alice);
        pool.batchClaimRewardShares(epochs);

        uint256 aliceReward = botcoin.balanceOf(alice) - aliceBefore;
        // Epoch 3: 500 * 0.95 = 475 (alice is sole depositor → 100%)
        // Epoch 4: 300 * 0.95 = 285 (alice is sole depositor → 100%)
        assertEq(aliceReward, 475 ether + 285 ether);
    }

    function test_batchClaimRewardShares_skipsAlreadyClaimed() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        // Alice claims normally first
        vm.prank(alice);
        pool.claimRewardShare(3);

        // Now batch claim including epoch 3 — should skip without reverting
        // (but will revert with NoRewards since there's nothing new to claim)
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 3;
        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.NoRewards.selector);
        pool.batchClaimRewardShares(epochs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Preview Reward Share
    // ═══════════════════════════════════════════════════════════════════════

    function test_previewRewardShare() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        assertEq(pool.previewRewardShare(alice, 3), 570 ether);
        assertEq(pool.previewRewardShare(bob, 3), 380 ether);
        assertEq(pool.previewRewardShare(carol, 3), 0); // no deposit
    }

    function test_previewRewardShare_beforeClaim() public {
        _setupEpoch3WithDeposits();
        assertEq(pool.previewRewardShare(alice, 3), 0); // not claimed yet
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Claim Window & Expired Reward Sweep
    // ═══════════════════════════════════════════════════════════════════════

    function test_isClaimWindowOpen() public {
        _setupEpoch3WithDeposits();

        assertTrue(pool.isClaimWindowOpen(3));

        vm.warp(pool.epochEndTime(3) + CLAIM_WINDOW + 1);
        assertFalse(pool.isClaimWindowOpen(3));
    }

    function test_sweepExpiredRewards() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        // Warp past claim window
        vm.warp(pool.epochEndTime(3) + CLAIM_WINDOW + 1);

        uint256 ownerBefore = botcoin.balanceOf(owner);
        pool.sweepExpiredRewards(3, owner);
        uint256 swept = botcoin.balanceOf(owner) - ownerBefore;
        assertEq(swept, 950 ether); // all depositor rewards unclaimed
    }

    function test_sweepExpiredRewards_revertsBeforeWindowExpires() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        // Still within window
        vm.expectRevert(BotcoinMiningPool.ClaimWindowNotExpired.selector);
        pool.sweepExpiredRewards(3, owner);
    }

    function test_sweepExpiredRewards_onlyOwner() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        vm.warp(pool.epochEndTime(3) + CLAIM_WINDOW + 1);

        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        pool.sweepExpiredRewards(3, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Operator Management
    // ═══════════════════════════════════════════════════════════════════════

    function test_transferOperator_twoStep() public {
        address newOp = makeAddr("newOp");

        pool.transferOperator(newOp);
        assertEq(pool.pendingOperator(), newOp);
        assertEq(pool.operator(), operator); // not yet changed

        vm.prank(newOp);
        pool.acceptOperator();
        assertEq(pool.operator(), newOp);
        assertEq(pool.pendingOperator(), address(0));
    }

    function test_transferOperator_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        pool.transferOperator(alice);
    }

    function test_acceptOperator_revertsWrongCaller() public {
        pool.transferOperator(makeAddr("newOp"));

        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.NotPendingOperator.selector);
        pool.acceptOperator();
    }

    function test_setOperatorFee() public {
        pool.setOperatorFee(1000); // 10%
        assertEq(pool.operatorFeeBps(), 1000);
    }

    function test_setOperatorFee_revertsTooHigh() public {
        vm.expectRevert(BotcoinMiningPool.FeeTooHigh.selector);
        pool.setOperatorFee(2001);
    }

    function test_setOperatorFee_maxAllowed() public {
        pool.setOperatorFee(2000); // exactly max
        assertEq(pool.operatorFeeBps(), 2000);
    }

    function test_withdrawOperatorFees() public {
        _setupEpoch3WithDeposits();

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        assertEq(pool.accumulatedOperatorFees(), 50 ether);

        uint256 opBefore = botcoin.balanceOf(operator);
        vm.prank(operator);
        pool.withdrawOperatorFees(operator);
        assertEq(botcoin.balanceOf(operator) - opBefore, 50 ether);
        assertEq(pool.accumulatedOperatorFees(), 0);
    }

    function test_withdrawOperatorFees_revertsNonOperator() public {
        vm.prank(alice);
        vm.expectRevert(BotcoinMiningPool.NotOperator.selector);
        pool.withdrawOperatorFees(alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Admin Config Updates
    // ═══════════════════════════════════════════════════════════════════════

    function test_setClaimWindow() public {
        pool.setClaimWindow(14 days);
        assertEq(pool.claimWindow(), 14 days);
    }

    function test_setGracePeriod() public {
        pool.setGracePeriod(2 hours);
        assertEq(pool.claimGracePeriod(), 2 hours);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Full Lifecycle Integration
    // ═══════════════════════════════════════════════════════════════════════

    function test_fullLifecycle() public {
        // --- Epoch 3: deposit phase ---
        mining.setCurrentEpoch(2); // deposits target epoch 3

        vm.prank(alice);
        pool.deposit(60_000_000 ether);
        vm.prank(bob);
        pool.deposit(40_000_000 ether);

        assertEq(pool.epochTier(3), 3); // 100M total → tier 3

        // --- Epoch 3: mining phase (operator submits receipts) ---
        mining.setCurrentEpoch(3);
        bytes memory receiptData = abi.encodeWithSignature("submitReceipt(bytes32,bytes)", bytes32(0), hex"aabb");
        vm.prank(operator);
        pool.submitReceiptToMining(receiptData);

        // --- Epoch 3 ends, rewards available ---
        mining.setCurrentEpoch(5);
        vm.warp(pool.epochEndTime(3) + 1);

        // Fund mining contract with rewards
        botcoin.mint(address(mining), 10_000 ether);
        mining.setNextClaimPayout(10_000 ether);

        // Operator claims epoch reward
        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        // 10,000 total, 5% fee = 500, depositors get 9,500
        assertEq(pool.epochRewards(3), 9_500 ether);
        assertEq(pool.accumulatedOperatorFees(), 500 ether);

        // --- Depositors claim their shares ---
        uint256 aliceBefore = botcoin.balanceOf(alice);
        vm.prank(alice);
        pool.claimRewardShare(3);
        assertEq(botcoin.balanceOf(alice) - aliceBefore, 5_700 ether); // 60% of 9500

        uint256 bobBefore = botcoin.balanceOf(bob);
        vm.prank(bob);
        pool.claimRewardShare(3);
        assertEq(botcoin.balanceOf(bob) - bobBefore, 3_800 ether); // 40% of 9500

        // --- Depositors withdraw original deposits ---
        vm.prank(alice);
        pool.withdraw(3);
        vm.prank(bob);
        pool.withdraw(3);

        // --- Operator withdraws fees ---
        vm.prank(operator);
        pool.withdrawOperatorFees(operator);
        assertEq(pool.accumulatedOperatorFees(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Fuzz Tests
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_deposit_withdraw_roundtrip(uint256 amount) public {
        amount = bound(amount, 1, 100_000_000 ether);

        botcoin.mint(alice, amount);
        vm.startPrank(alice);
        botcoin.approve(address(pool), amount);
        pool.deposit(amount);

        uint256 targetEpoch = pool.currentEpoch() + 1;
        assertEq(pool.deposits(alice, targetEpoch), amount);

        // Advance past epoch end
        vm.stopPrank();
        vm.warp(pool.epochEndTime(targetEpoch) + 1);

        uint256 balBefore = botcoin.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw(targetEpoch);
        assertEq(botcoin.balanceOf(alice) - balBefore, amount);
    }

    function testFuzz_rewardDistribution_sumMatchesTotal(
        uint256 aliceDeposit,
        uint256 bobDeposit,
        uint256 rewardAmount
    ) public {
        aliceDeposit = bound(aliceDeposit, 1 ether, 100_000_000 ether);
        bobDeposit = bound(bobDeposit, 1 ether, 100_000_000 ether);
        rewardAmount = bound(rewardAmount, 1 ether, 1_000_000 ether);

        mining.setCurrentEpoch(2);

        botcoin.mint(alice, aliceDeposit);
        vm.prank(alice);
        botcoin.approve(address(pool), aliceDeposit);
        vm.prank(alice);
        pool.deposit(aliceDeposit);

        botcoin.mint(bob, bobDeposit);
        vm.prank(bob);
        botcoin.approve(address(pool), bobDeposit);
        vm.prank(bob);
        pool.deposit(bobDeposit);

        mining.setCurrentEpoch(5);
        vm.warp(pool.epochEndTime(3) + 1);

        botcoin.mint(address(mining), rewardAmount);
        mining.setNextClaimPayout(rewardAmount);

        vm.prank(operator);
        pool.claimEpochReward(3, _claimCalldata(3));

        uint256 depositorPool = pool.epochRewards(3);

        // Preview shares
        uint256 aliceShare = pool.previewRewardShare(alice, 3);
        uint256 bobShare = pool.previewRewardShare(bob, 3);

        // Sum of shares should not exceed total (may have dust from rounding)
        assertLe(aliceShare + bobShare, depositorPool);
        // Dust should be minimal (< 2 wei)
        assertLe(depositorPool - (aliceShare + bobShare), 1);
    }

    function testFuzz_tierThresholds(uint256 amount) public {
        amount = bound(amount, 0, 200_000_000 ether);

        if (amount > 0) {
            botcoin.mint(alice, amount);
            vm.prank(alice);
            botcoin.approve(address(pool), amount);
            vm.prank(alice);
            pool.deposit(amount);
        }

        uint256 targetEpoch = pool.currentEpoch() + 1;
        uint8 tier = pool.epochTier(targetEpoch);

        if (amount >= TIER3) assertEq(tier, 3);
        else if (amount >= TIER2) assertEq(tier, 2);
        else if (amount >= TIER1) assertEq(tier, 1);
        else assertEq(tier, 0);
    }
}

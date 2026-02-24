// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBotcoinMining} from "../../src/interfaces/IBotcoinMining.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockMiningContract
/// @notice Test double that simulates the BOTCOIN mining contract.
///         Exposes setters so tests can control epoch state and claim payouts.
contract MockMiningContract is IBotcoinMining {
    uint256 private _currentEpoch;
    mapping(uint256 => uint256) private _epochEndTimes;
    mapping(address => mapping(uint256 => uint256)) private _minerCredits;
    mapping(uint256 => uint256) private _totalCredits;

    /// @notice Token to pay out on claim (set by test)
    IERC20 public rewardToken;

    /// @notice Amount to transfer on next claim call (set by test)
    uint256 public nextClaimPayout;

    /// @notice Whether next submitReceipt call should succeed
    bool public receiptAccepted = true;

    /// @notice Last calldata received by submitReceipt
    bytes public lastReceiptCalldata;

    /// @notice Selector for the mock claim function
    bytes4 public constant CLAIM_SELECTOR = bytes4(keccak256("claim(uint256[])"));

    // ─── IBotcoinMining Implementation ────────────────────────────────────

    function currentEpoch() external view override returns (uint256) {
        return _currentEpoch;
    }

    function getEpochEndTime(uint256 epochId) external view override returns (uint256) {
        return _epochEndTimes[epochId];
    }

    function minerEpochCredits(address miner, uint256 epochId) external view override returns (uint256) {
        return _minerCredits[miner][epochId];
    }

    function totalEpochCredits(uint256 epochId) external view override returns (uint256) {
        return _totalCredits[epochId];
    }

    // ─── Test Setters ─────────────────────────────────────────────────────

    function setCurrentEpoch(uint256 epoch) external {
        _currentEpoch = epoch;
    }

    function setEpochEndTime(uint256 epochId, uint256 endTime) external {
        _epochEndTimes[epochId] = endTime;
    }

    function setMinerCredits(address miner, uint256 epochId, uint256 credits) external {
        _minerCredits[miner][epochId] = credits;
    }

    function setTotalCredits(uint256 epochId, uint256 credits) external {
        _totalCredits[epochId] = credits;
    }

    function setRewardToken(address token) external {
        rewardToken = IERC20(token);
    }

    function setNextClaimPayout(uint256 amount) external {
        nextClaimPayout = amount;
    }

    function setReceiptAccepted(bool accepted) external {
        receiptAccepted = accepted;
    }

    // ─── Receive Functions (called by pool via .call) ─────────────────────

    /// @notice Mock claim function — transfers `nextClaimPayout` of rewardToken to caller
    function claim(uint256[] calldata /* epochIds */) external {
        if (nextClaimPayout > 0 && address(rewardToken) != address(0)) {
            rewardToken.transfer(msg.sender, nextClaimPayout);
            nextClaimPayout = 0; // reset after payout
        }
    }

    /// @notice Catch-all for submitReceipt and other forwarded calls
    fallback() external payable {
        if (!receiptAccepted) {
            revert("MockMining: receipt rejected");
        }
        lastReceiptCalldata = msg.data;
    }

    receive() external payable {}
}

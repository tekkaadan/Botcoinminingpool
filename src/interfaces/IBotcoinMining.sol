// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBotcoinMining
/// @notice Minimal interface for the BOTCOIN mining contract.
/// @dev The pool reads epoch state from this contract rather than maintaining
///      its own epoch clock. Adjust function signatures if the deployed mining
///      contract uses different names — the semantics must match.
interface IBotcoinMining {
    /// @notice Returns the current active epoch ID.
    function currentEpoch() external view returns (uint256);

    /// @notice Returns the timestamp at which a given epoch ends (exclusive).
    /// @dev    After this timestamp the epoch is considered closed and rewards
    ///         may be claimed once funded.
    function getEpochEndTime(uint256 epochId) external view returns (uint256);

    /// @notice Returns the number of mining credits a miner earned in an epoch.
    function minerEpochCredits(address miner, uint256 epochId) external view returns (uint256);

    /// @notice Returns the total mining credits across all miners for an epoch.
    function totalEpochCredits(uint256 epochId) external view returns (uint256);
}

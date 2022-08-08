// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.3;

/// @title Blocklist Checker interface
/// @notice Basic blocklist checker interface for VotingEscrow
interface IBlocklist {
    function isBlocked(address addr) external view returns (bool);
}

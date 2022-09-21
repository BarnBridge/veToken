// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.3;

import { IVotingEscrow } from "./interfaces/IVotingEscrow.sol";

/// @title A blocklist for contracts
/// @notice Allows blocking of contracts. Blocking a contract also
/// forces the undelegation of that lock in the VotingEscrow contract
/// @dev Blocking can be circumvented by a deterministically created
/// (create2) contract that selfdestructs after execution of instructions
/// In such a scenario the Blocklist may have to be replaced with new
/// one that also supports blocking of addresses in general
contract Blocklist {
    mapping(address => bool) private _blocklist;
    address public immutable manager;
    address public immutable ve;

    /// @notice Initializes state
    /// @param _manager Owner of the blocklist contract
    /// @param _ve Address of the `VotingEscrow` contract
    constructor(address _manager, address _ve) {
        manager = _manager;
        ve = _ve;
    }

    /// @notice Add address to blocklist
    /// @param addr The contract address to blocklist
    /// @dev Is only callable by the Blocklist owner
    /// Allows blocklisting only of contracts
    function blockContract(address addr) external {
        require(msg.sender == manager, "Only manager");
        require(addr.code.length > 0, "Only contracts");
        _blocklist[addr] = true;
        IVotingEscrow(ve).forceUndelegate(addr);
    }

    /// @notice Check an address
    /// @param addr The contract address to check
    /// @return Whether `addr` is blocked or not
    /// @dev This method will be called by the VotingEscrow contract
    function isBlocked(address addr) external view returns (bool) {
        return _blocklist[addr];
    }
}

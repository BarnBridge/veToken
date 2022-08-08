// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.3;

/// @title Blocklist Checker implementation.
/// @notice Checks if an address is blocklisted
/// @dev This is a basic implementation using a mapping for address => bool
contract Blocklist {
    mapping(address => bool) private _blocklist;
    address public manager;

    constructor(address _manager) {
        manager = _manager;
    }

    /// @notice Add address to blocklist
    /// @dev only callable by owner.
    /// @dev Allows blocklisting only of smart contracts
    /// @param addr The contract address to blocklist
    function block(address addr) external {
        require(msg.sender == manager, "Only manager");
        require(_isContract(addr), "Only contracts");
        _blocklist[addr] = true;
    }

    /// @notice Check an address
    /// @dev This method will be called by the VotingEscrow contract
    /// @param addr The contract address to check
    function isBlocked(address addr) public view returns (bool) {
        return _blocklist[addr];
    }

    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}

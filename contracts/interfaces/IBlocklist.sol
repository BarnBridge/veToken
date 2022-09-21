// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.3;

interface IBlocklist {
    function isBlocked(address addr) external view returns (bool);
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.3;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IDelegatedVotingEscrow
} from "../interfaces/IDelegatedVotingEscrow.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockSmartWallet {
    IERC20 public fdt;

    constructor(IERC20 _fdt) {
        fdt = _fdt;
    }

    function createLock(
        address ve,
        uint256 amount,
        uint256 end
    ) external {
        fdt.approve(ve, amount);
        IDelegatedVotingEscrow(ve).createLock(amount, end);
    }

    function increaseAmount(address ve, uint256 amount) external {
        fdt.approve(ve, amount);
        IDelegatedVotingEscrow(ve).increaseAmount(amount);
    }

    function increaseUnlockTime(address ve, uint256 unlockTime) external {
        IDelegatedVotingEscrow(ve).increaseUnlockTime(unlockTime);
    }

    function quitLock(address ve) external {
        IDelegatedVotingEscrow(ve).quitLock();
    }

    function withdraw(address ve) external {
        IDelegatedVotingEscrow(ve).withdraw();
    }

    function delegate(address ve, address to) external {
        IDelegatedVotingEscrow(ve).delegate(to);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockBotcoin
/// @notice Simplified ERC-20 for testing. Anyone can mint.
contract MockBotcoin is ERC20 {
    constructor() ERC20("BOTCOIN", "BOTCOIN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

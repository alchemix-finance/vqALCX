// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockALCX is ERC20 {
    constructor() ERC20("Alchemix", "ALCX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockReward is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

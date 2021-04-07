// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import {IERC20 as SIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDOG is SIERC20 {
    function mint(address to, uint256 amount) external returns (bool);
    function totalSupply() external override view returns (uint256);
}
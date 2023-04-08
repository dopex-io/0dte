// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Router} from "../interface/IUniswapV3Router.sol";

contract MockUniswapV3Router {
    function exactInputSingle(IUniswapV3Router.ExactInputSingleParams calldata) external payable returns (uint256) {
      return 1 ether;
    }
}

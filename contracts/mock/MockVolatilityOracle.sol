// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

contract MockVolatilityOracle {
    function getVolatility(uint256 _strike) external pure returns (uint256) {
        return 100;
    }
}

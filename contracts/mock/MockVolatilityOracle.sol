// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "../interface/IVolatilityOracle.sol";

contract MockVolatilityOracle is IVolatilityOracle {
    function getVolatility(bytes32,uint256,uint256) external pure returns (uint256) {
        return 100;
    }
}

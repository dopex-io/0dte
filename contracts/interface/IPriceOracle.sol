//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IPriceOracle {
    function getCollateralPrice() external view returns (uint256);

    function getUnderlyingPrice() external view returns (uint256);
}

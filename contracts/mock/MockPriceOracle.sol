// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

contract MockPriceOracle {
    uint256 lastPrice = 1000 * 10 ** 8;

    function getUnderlyingPrice() external view returns (uint256) {
        return lastPrice;
    }

    function updateUnderlyingPrice(uint256 price) external {
        lastPrice = price;
    }
}

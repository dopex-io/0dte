// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/Script.sol";
import {Zdte} from "../contracts/Zdte.sol";
import {MockUniswapV3Router} from "../contracts/mock/MockUniswapV3Router.sol";

// cat broadcast/Deploy.s.sol/421613/run-latest.json | jq '[.transactions | .[] | select(.transactionType == "CREATE") | {(.contractName): .contractAddress}] | add'
contract DeployScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        Zdte zdte = new Zdte({
            _base: vm.envAddress("ETH"),
            _quote: vm.envAddress("USDC"),
            _optionPricing: vm.envAddress("OPTION_PRICING"),
            _volatilityOracle: vm.envAddress("VOLATILITY"),
            _priceOracle: vm.envAddress("PRICE_ORACLE"),
            _uniswapV3Router: vm.envAddress("ROUTER"),
            _feeDistributor: vm.envAddress("FEE_DISTRIBUTOR"),
            _strikeIncrement: vm.envUint("STRIKE_INCREMENT"),
            _maxOtmPercentage: vm.envUint("OTM_PCT"),
            _genesisExpiry: vm.envUint("EXPIRY")
        });
        vm.label(address(zdte), "zdte");

        vm.stopBroadcast();
    }
}

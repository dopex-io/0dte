// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/Script.sol";
import {Zdte} from "../contracts/Zdte.sol";

// cat broadcast/Deploy.s.sol/421613/run-latest.json | jq '[.transactions | .[] | select(.transactionType == "CREATE") | {(.contractName): .contractAddress}] | add'
contract DeployEthScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        Zdte zdte = new Zdte({
            _base: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            _quote: 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8,
            _optionPricing: 0x35cFa5Ac5edb29769F92e16B6b68Efa60B810a8E,
            _volatilityOracle: 0x7DA1b58f0A7cBb70f756A01412842D5a8796454E,
            _priceOracle: 0x19e6eE4C2cBe7Bcc4cd1ef0BCF7e764fECe23cC6,
            _uniswapV3Router: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
            _feeDistributor: 0xDe485812E28824e542B9c2270B6b8eD9232B7D0b,
            _strikeIncrement: 2500000000,
            _maxOtmPercentage: 10,
            _genesisExpiry: vm.envUint("EXPIRY"),
            _oracleId: "ETH-USD-ZDTE"
        });
        vm.label(address(zdte), "eth-zdte");

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/Script.sol";
import {Zdte} from "../contracts/Zdte.sol";

// cat broadcast/Deploy.s.sol/421613/run-latest.json | jq '[.transactions | .[] | select(.transactionType == "CREATE") | {(.contractName): .contractAddress}] | add'
contract DeployArbScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        Zdte zdte = new Zdte({
            _base: 0x912CE59144191C1204E64559FE8253a0e49E6548,
            _quote: 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8,
            _optionPricing: 0x2b99e3D67dAD973c1B9747Da742B7E26c8Bdd67B,
            _volatilityOracle: 0x7DA1b58f0A7cBb70f756A01412842D5a8796454E,
            _priceOracle: 0x94C929722eE804ae25735839C041fc828732b05E,
            _uniswapV3Router: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
            _feeDistributor: 0x55594cCe8cC0014eA08C49fd820D731308f204c1,
            _strikeIncrement: 5000000,
            _maxOtmPercentage: 20,
            _genesisExpiry: vm.envUint("EXPIRY"),
            _oracleId: "ARB-USD-ZDTE"
        });
        vm.label(address(zdte), "arb-zdte");

        vm.stopBroadcast();
    }
}

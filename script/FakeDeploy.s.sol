// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/Script.sol";
import {Zdte} from "../contracts/Zdte.sol";
import {MockUniswapV3Router} from "../contracts/mock/MockUniswapV3Router.sol";

// cat broadcast/Deploy.s.sol/421613/run-latest.json | jq '[.transactions | .[] | select(.transactionType == "CREATE") | {(.contractName): .contractAddress}] | add'
contract FakeDeployScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        Zdte zdte = new Zdte(
          0x36EbEeC09CefF4a060fFfa27D3a227F51Ce20919,
          0xBB6f4E606344a709B5258d1127d268421Ea79B1d,
          0xdFF1012E6D6e0d46FcF61eF16593D82EF6bD2b39,
          0x43dA03eF7C69B40e151f7de88dF75ff935c8776A,
          0xef84Ce91Bd262CA8Bfd7484ec4e192c07230c73C,
          0x260019BF63A233aE5d6145e609DC8B35e48FD5A4,
          0x9d16d832dD97eD9684DaE9CD30234bB7028EBfDf,
          50e8,
          10,
          0,
          "FAKE"
        );
        vm.label(address(zdte), "zdte");

        vm.stopBroadcast();
    }
}

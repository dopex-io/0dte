// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/Script.sol";
import {Zdte} from "../contracts/Zdte.sol";
import {MockERC20} from "../contracts/mock/MockERC20.sol";

// cat broadcast/Deploy.s.sol/421613/run-latest.json | jq '[.transactions | .[] | select(.transactionType == "CREATE") | {(.contractName): .contractAddress}] | add'
contract DeployScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        MockERC20 usdcToken = new MockERC20("USDC", "USDC", 6);
        vm.label(address(usdcToken), "usdc token");

        Zdte zdte = new Zdte(
          0x36EbEeC09CefF4a060fFfa27D3a227F51Ce20919,
          address(usdcToken),
          0xdFF1012E6D6e0d46FcF61eF16593D82EF6bD2b39,
          0x43dA03eF7C69B40e151f7de88dF75ff935c8776A,
          0xef84Ce91Bd262CA8Bfd7484ec4e192c07230c73C,
          0x1085A7C754e765233bf63D56dC7e607F5214Cd2f,
          50e8,
          10,
          1679745600
        );
        vm.label(address(zdte), "zdte");

        vm.stopBroadcast();
    }
}

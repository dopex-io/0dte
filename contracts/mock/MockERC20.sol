// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

contract MockERC20 is ERC20PresetMinterPauser {
    uint8 private _decimals = 18;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20PresetMinterPauser(name, symbol) {
        _decimals = decimals_;
        _mint(address(msg.sender), 1000e8 ether);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}

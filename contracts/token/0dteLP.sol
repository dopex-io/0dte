// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// Contracts
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC4626} from "solmate/src/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

// Libraries
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {0dte} from '../0dte.sol';

/**
 * @title 0dte LP Token
 */
contract 0dteLP is ERC4626 {

    using SafeTransferLib for ERC20;

    /// @dev The address of the 0dte contract creating the lp token
    0dte public 0dte;

    /// @dev The address of the collateral contract for the 0dte lp
    ERC20 public collateral;

    /// @dev The symbol reperesenting the underlying asset of the 0dte lp
    string public underlyingSymbol;

    /// @dev The symbol representing the collateral token of the 0dte lp
    string public collateralSymbol;

    // @dev Total collateral assets available
    uint public _totalAssets;

    // @dev Locked liquidity in active 0dte positions
    uint public _lockedLiquidity;

    /*==== CONSTRUCTOR ====*/
    /**
     * @param _0dte The address of the 0dte contract creating the lp token
     * @param _collateral The address of the collateral asset in the 0dte contract
     * @param _collateralSymbol The symbol of the collateral asset token
     */
    constructor(
        address _0dte,
        address _collateral,
        string memory _collateralSymbol
    ) ERC4626(ERC20(_collateral), "0dte LP Token", "0dteLP") {
        0dte = 0dte(_0dte);
        collateralSymbol = _collateralSymbol;

        symbol = concatenate(_collateralSymbol, "-LP");
    }

    /*==== PURE FUNCTIONS ====*/

    /**
     * @notice Returns a concatenated string of a and b
     * @param _a string a
     * @param _b string b
     */
    function concatenate(string memory _a, string memory _b)
        internal
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(_a, _b));
    }

    function totalAssets() public view virtual override returns (uint) {
        return _totalAssets;
    }

    function totalAvailableAssets() public view returns (uint) {
        return _totalAssets - _lockedLiquidity;
    }

    function lockLiquidity(uint amount) public  {
        require(msg.sender == address(0dte), "Only 0dte can call this function");
        _lockedLiquidity += amount;
    }

    function unlockLiquidity(uint amount) public {
        require(msg.sender == address(0dte), "Only 0dte can call this function");
        _lockedLiquidity -= amount;
    }

    // Adds premium and fees to total available assets
    function addProceeds(uint proceeds) public {
        require(msg.sender == address(0dte), "Only 0dte can call this function");
        _totalAssets += proceeds;
    }

    // Subtract loss from total available assets
    function subtractLoss(uint loss) public {
        require(msg.sender == address(0dte), "Only 0dte can call this function");
        _totalAssets -= loss;
    }

    function beforeWithdraw(uint256 assets, uint256 /*shares*/ ) internal virtual override {
        require(assets <= totalAvailableAssets(), "Not enough available assets to satisfy withdrawal");
        /// -----------------------------------------------------------------------
        /// Withdraw assets from 0dte contract
        /// -----------------------------------------------------------------------
        0dte.claimCollateral(assets);
        _totalAssets -= assets;
    }

    function afterDeposit(uint256 assets, uint256 /*shares*/ ) internal virtual override {
        /// -----------------------------------------------------------------------
        /// Deposit assets into 0dte contract
        /// -----------------------------------------------------------------------
        _totalAssets += assets;
        // approve to 0dte
        asset.safeApprove(address(0dte), assets);
        // deposit into 0dte
        asset.safeTransfer(address(0dte), assets);
    }
}

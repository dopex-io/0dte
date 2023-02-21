// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "./interface/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";

import {0dteLP} from "./token/0dteLP.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {0dtePositionMinter} from "./positions/0dtePositionMinter.sol";

import {Pausable} from "./helpers/Pausable.sol";

import {IOptionPricing} from "./interface/IOptionPricing.sol";
import {IVolatilityOracle} from "./interface/IVolatilityOracle.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {IUniswapV3Router} from "./interface/IUniswapV3Router.sol";

import "hardhat/console.sol";

contract 0dte is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // Base token
    IERC20 public base;
    // Quote token
    IERC20 public quote;
    // 0dte Base LP token
    0dteLP public baseLp;
    // 0dte Quotee LP token
    0dteLP public quoteLp;

    // Option pricing
    IOptionPricing public optionPricing;
    // Volatility oracle
    IVolatilityOracle public volatilityOracle;
    // Price oracle
    IPriceOracle public priceOracle;
    // 0dte position minter
    0dtePositionMinter public 0dtePositionMinter;
    // Fee distributor
    address public feeDistributor;
    // Uniswap V3 router
    IUniswapV3Router public uniswapV3Router;

    // Fees for opening position
    uint256 public feeOpenPosition = 5000000; // 0.05%

    uint256 public constant divisor = 1e8;

    // Strike increments
    uint256 public strikeIncrement;

    // Max OTM % from mark price
    uint256 public maxOtmPercentage;

    // 0dte positions
    mapping(uint256 => 0dtePosition) public 0dtePositions;

    struct 0dtePosition {
        // Is position open
        bool isOpen;
        // Is short
        bool isPut;
        // Open position count (in base asset)
        uint256 positions;
        // Strike price
        uint256 strike;
        // Premium for position
        uint256 premium;
        // Fees for position
        uint256 fees;
        // Final PNL of position
        int256 pnl;
        // Opened at timestamp
        uint256 openedAt;
    }

    // Deposit event
    event Deposit(bool isQuote, uint256 amount, address indexed sender);

    // Withdraw event
    event Withdraw(bool isQuote, uint256 amount, address indexed sender);

    // Long option position event
    event LongOptionPosition(uint256 id, uint256 amount, uint256 strike, address indexed user);

    // Expire option position event
    event ExpireOptionPosition(uint256 id, int256 pnl, address indexed user);

    constructor(
        address _base,
        address _quote,
        address _optionPricing,
        address _volatilityOracle,
        address _priceOracle,
        address _uniswapV3Router,
        uint _strikeIncrement,
        uint _maxOtmPercentage
    ) {
        require(_base != address(0), "Invalid base token");
        require(_quote != address(0), "Invalid quote token");
        require(_optionPricing != address(0), "Invalid option pricing");
        require(_volatilityOracle != address(0), "Invalid volatility oracle");
        require(_priceOracle != address(0), "Invalid price oracle");

        require(_strikeIncrement > 0, "Invalid strike increment");
        require(_maxOtmPercentage > 0, "Invalid max OTM %");

        base = IERC20(_base);
        quote = IERC20(_quote);
        optionPricing = IOptionPricing(_optionPricing);
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        priceOracle = IPriceOracle(_priceOracle);
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);

        strikeIncrement = _strikeIncrement;
        maxOtmPercentage = _maxOtmPercentage;

        0dtePositionMinter = new 0dtePositionMinter();

        base.approve(address(uniswapV3Router), type(uint256).max);
        quote.approve(address(uniswapV3Router), type(uint256).max);

        quoteLp = new 0dteLP(address(this), address(quote), quote.symbol());

        baseLp = new 0dteLP(address(this), address(base), base.symbol());

        quote.approve(address(quoteLp), type(uint256).max);
        base.approve(address(baseLp), type(uint256).max);
    }

    /// @notice Internal function to handle swaps using Uniswap V3 exactIn
    /// @param from Address of the token to sell
    /// @param to Address of the token to buy
    /// @param amountOut Target amount of to token we want to receive
    function _swapExactIn(
        address from,
        address to,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        return
            uniswapV3Router.exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: from,
                    tokenOut: to,
                    fee: 500,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    // Deposit assets
    // @param isQuote If true user deposits quote token (else base)
    // @param amount Amount of quote asset to deposit to LP
    function deposit(bool isQuote, uint256 amount) public {
        if (isQuote) {
            quote.transferFrom(msg.sender, address(this), amount);
            quoteLp.deposit(amount, msg.sender);
        } else {
            base.transferFrom(msg.sender, address(this), amount);
            baseLp.deposit(amount, msg.sender);
        }
        emit Deposit(isQuote, amount, msg.sender);
    }

    // Withdraw
    // @param isQuote If true user withdraws quote token (else base)
    // @param amount Amount of LP positions to withdraw
    function withdraw(bool isQuote, uint256 amount) public {
        if (isQuote) {
            quoteLp.redeem(amount, msg.sender, msg.sender);
        } else {
            baseLp.redeem(amount, msg.sender, msg.sender);
        }
        emit Withdraw(isQuote, amount, msg.sender);
    }

    /// @notice Buys a 0dte option
    function longOptionPosition(
        bool isPut,
        uint256 amount,
        uint256 strike
    ) public returns (uint256 id) {
        uint256 markPrice = getMarkPrice();

        require(
            strike >= markPrice - markPrice * (100 - maxOtmPercentage) && 
            strike <= markPrice + markPrice * (100 - maxOtmPercentage) &&
            strike % strikeIncrement == 0,
            "Invalid strike"
        );

        // Calculate premium for ATM option in quote
        uint256 premium = calcPremium(
            strike,
            amount,
            1 days
        );

        // Calculate opening fees in quote
        uint256 openingFees = calcFees(amount * markPrice);

        // We transfer premium + fees from user
        quote.transferFrom(msg.sender, address(this), premium + openingFees);

        uint256 swapped;
        uint256 entry;

        if (isPut) {
            require(quoteLp.totalAvailableAssets() >= amount * strike, "Insufficient liquidity");
            quoteLp.lockLiquidity(amount * strike);
        } else {
            require(baseLp.totalAvailableAssets() >= amount, "Insufficient liquidity");
            baseLp.lockLiquidity(amount);
        }

        // Transfer fees to fee distributor
        if (isPut) {
            quoteLp.deposit(openingFees, feeDistributor);
            quoteLp.addProceeds(basePremium);
        } else {
            uint256 basePremium = _swapExactIn(
                address(quote),
                address(base),
                premium
            );

            uint256 baseOpeningFees = _swapExactIn(
                address(quote),
                address(base),
                openingFees
            );
            baseLp.deposit(baseOpeningFees, feeDistributor);
            baseLp.addProceeds(basePremium);
        }

        // Generate 0dte position NFT
        id = 0dtePositionMinter.mint(msg.sender);

        0dtePositions[id] = 0dtePosition({
            isOpen: true,
            isPut: isPut,
            positions: amount,
            strike: strike,
            premium: premium,
            fees: openingFees,
            pnl: 0,
            openedAt: block.timestamp
        });

        emit LongOptionPosition(id, amount, strike, msg.sender);
    }

    /// @notice Expires an open option position
    /// @param id ID of position
    function expireOptionPosition(uint256 id) public {
        require(0dtePositions[id].isOpen, "Invalid position ID");

        require(
            0dtePositions[id].openedAt + 1 days <= block.timestamp,
            "Position must be expired"
        );

        int256 pnl = calcPnl(id);
        uint256 markPrice = getMarkPrice();

        if (0dtePositions[id].isPut) {
            quoteLp.unlockLiquidity(
                0dtePositions[id].entry * 0dtePositions[id].positions
            );
            quote.transfer(
                IERC721(0dtePositionMinter).ownerOf(id),
                uint256(pnl)
            );
        } else {
            baseLp.unlockLiquidity(0dtePositions[id].positions);
            base.transfer(
                IERC721(0dtePositionMinter).ownerOf(id),
                uint256(pnl)
            );
        }
        0dtePositions[id].isOpen = false;
        emit ExpireOptionPosition(id, pnl, msg.sender);
    }

    /// @notice Allow only 0dte LP contract to claim collateral
    /// @param amount Amount of quote/base assets to transfer
    function claimCollateral(uint256 amount) public {
        require(
            msg.sender == address(quoteLp) || msg.sender == address(baseLp),
            "Only 0dte LP contract can claim collateral"
        );
        if (msg.sender == address(quoteLp)) 
            quote.transfer(msg.sender, amount);
        else if (msg.sender == address(baseLp))
            base.transfer(msg.sender, amount);
    }

    /// @notice External function to return the volatility
    /// @param strike Strike of option
    function getVolatility(uint256 strike)
        public
        view
        returns (uint256 volatility)
    {
        volatility = uint256(volatilityOracle.getVolatility(strike));
    }

    /// @notice Internal function to calculate premium
    /// @param strike Strike of option
    /// @param amount Amount of option
    function calcPremium(
        uint256 strike,
        uint256 amount,
        uint256 timeToExpiry
    ) internal view returns (uint256 premium) {
        uint256 markPrice = getMarkPrice();
        uint256 expiry = block.timestamp + timeToExpiry;
        premium = uint256(
            optionPricing.getOptionPrice(
                false,
                expiry,
                strike,
                markPrice,
                getVolatility(strike)
            )
        ) * amount; // ATM options: does not matter if call or put

        premium = premium / (divisor / uint256(10**quote.decimals()));
    }

    /// @notice Internal function to calculate fees
    /// @param amount Value of option in USD (ie6)
    function calcFees(uint256 amount) internal view returns (uint256 fees) {
        fees = (amount * feeOpenPosition) / (100 * divisor);
    }

    /// @notice Internal function to calculate pnl
    /// @param id ID of position
    function calcPnl(uint256 id) internal view returns (int256 pnl) {
        uint256 markPrice = getMarkPrice();
        uint256 strike = 0dtePositions[id].strike;
        if (0dtePositions[id].isPut)
            pnl = strike > markPrice ? int256(0dtePositions[id].positions) *
                (int256(strike) - int256(markPrice)) /
                10**8 : 0;
        else
            pnl = markPrice > strike ? (int256(0dtePositions[id].positions) *
                (int256(markPrice) - int256(strike))/int256(markPrice)) /
                10**8 : 0;
    }

    /// @notice Public function to retrieve price of base asset from oracle
    /// @param price Mark price
    function getMarkPrice() public view returns (uint256 price) {
        price = uint256(priceOracle.getUnderlyingPrice());
    }

    function checkMath() public view {
        console.log("QUOTE");
        console.log(quote.balanceOf(address(this)));
        console.log("QUOTE TOTAL ASSETS");
        console.log(quoteLp.totalAssets());
        console.log("QUOTE TOTAL AVAILABLE ASSETS");
        console.log(quoteLp.totalAvailableAssets());

        console.log("BASE");
        console.log(base.balanceOf(address(this)));
        console.log("BASE TOTAL ASSETS");
        console.log(baseLp.totalAssets());
        console.log("BASE TOTAL AVAILABLE ASSETS");
        console.log(baseLp.totalAvailableAssets());
    }
    
}
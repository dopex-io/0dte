// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ZdteLP} from "./token/ZdteLP.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ZdtePositionMinter} from "./positions/ZdtePositionMinter.sol";

import {ContractWhitelist} from "./helpers/ContractWhitelist.sol";

import {IOptionPricing} from "./interface/IOptionPricing.sol";
import {IVolatilityOracle} from "./interface/IVolatilityOracle.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {IUniswapV3Router} from "./interface/IUniswapV3Router.sol";

import "hardhat/console.sol";

contract Zdte is ReentrancyGuard, Ownable, Pausable, ContractWhitelist {
    using SafeERC20 for IERC20Metadata;

    // Base token
    IERC20Metadata public base;
    // Quote token
    IERC20Metadata public quote;
    // zdte Base LP token
    ZdteLP public baseLp;
    // zdte Quotee LP token
    ZdteLP public quoteLp;

    // Option pricing
    IOptionPricing public optionPricing;
    // Volatility oracle
    IVolatilityOracle public volatilityOracle;
    // Price oracle
    IPriceOracle public priceOracle;
    // zdte position minter
    ZdtePositionMinter public zdtePositionMinter;
    // Fee distributor
    address public feeDistributor;
    // Uniswap V3 router
    IUniswapV3Router public uniswapV3Router;

    // Fees for opening position
    uint256 public feeOpenPosition = 5000000; // 0.05%

    uint256 public constant STRIKE_DECIMALS = 1e8;

    uint256 internal constant AMOUNT_PRICE_TO_USDC_DECIMALS = (1e18 * 1e8) / 1e6;

    uint256 public spreadMarginSafety = 30000; // 300%

    // Strike increments
    uint256 public strikeIncrement;

    // Max OTM % from mark price
    uint256 public maxOtmPercentage;

    // Genesis expiry timestamp, next day 8am gmt
    uint256 public genesisExpiry;

    // base token liquidity
    uint256 public baseLpTokenLiquidty;

    // quote token liquidity
    uint256 public quoteLpTokenLiquidty;

    // zdte positions
    mapping(uint256 => ZdtePosition) public zdtePositions;

    enum PositionType {
        LONG_PUT,
        LONG_CALL,
        SPREAD_PUT,
        SPREAD_CALL
    }

    struct ZdtePosition {
        // Is position open
        bool isOpen;
        // Open position count (in base asset)
        uint256 positions;
        // Long strike price
        uint256 longStrike;
        // Short strike price
        uint256 shortStrike;
        // Long premium for position
        uint256 longPremium;
        // Short premium for position
        uint256 shortPremium;
        // Fees for position
        uint256 fees;
        // Final PNL of position
        int256 pnl;
        // Opened at timestamp
        uint256 openedAt;
        // Expiry timestamp
        uint256 expiry;
        // Position type
        PositionType positionType;
    }

    // Deposit event
    event Deposit(bool isQuote, uint256 amount, address indexed sender);

    // Withdraw event
    event Withdraw(bool isQuote, uint256 amount, address indexed sender);

    // Long option position event
    event LongOptionPosition(uint256 id, uint256 amount, uint256 strike, address indexed user);

    // Long option position event
    event SpreadOptionPosition(
        uint256 id, uint256 amount, uint256 longStrike, uint256 shortStrike, address indexed user
    );

    // Expire option position event
    event ExpireOptionPosition(uint256 id, uint256 pnl, address indexed user);

    // Claim collateral
    event ClaimCollateral(uint256 amount, address indexed sender);

    /*==== CONSTRUCTOR ====*/

    constructor(
        address _base,
        address _quote,
        address _optionPricing,
        address _volatilityOracle,
        address _priceOracle,
        address _uniswapV3Router,
        uint256 _strikeIncrement,
        uint256 _maxOtmPercentage,
        uint256 _genesisExpiry
    ) {
        require(_base != address(0), "Invalid base token");
        require(_quote != address(0), "Invalid quote token");
        require(_optionPricing != address(0), "Invalid option pricing");
        require(_volatilityOracle != address(0), "Invalid volatility oracle");
        require(_priceOracle != address(0), "Invalid price oracle");

        require(_strikeIncrement > 0, "Invalid strike increment");
        require(_maxOtmPercentage > 0, "Invalid max OTM %");
        require(_genesisExpiry > block.timestamp, "Invalid genesis expiry");

        base = IERC20Metadata(_base);
        quote = IERC20Metadata(_quote);
        optionPricing = IOptionPricing(_optionPricing);
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        priceOracle = IPriceOracle(_priceOracle);
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);

        strikeIncrement = _strikeIncrement;
        maxOtmPercentage = _maxOtmPercentage;
        genesisExpiry = _genesisExpiry;

        zdtePositionMinter = new ZdtePositionMinter();

        base.approve(address(uniswapV3Router), type(uint256).max);
        quote.approve(address(uniswapV3Router), type(uint256).max);

        quoteLp = new ZdteLP(address(this), address(quote), quote.symbol());
        baseLp = new ZdteLP(address(this), address(base), base.symbol());

        quote.approve(address(quoteLp), type(uint256).max);
        base.approve(address(baseLp), type(uint256).max);
    }

    /*==== USER METHODS ====*/

    /// @notice Deposit assets
    /// @param isQuote If true user deposits quote token (else base)
    /// @param amount Amount of quote asset to deposit to LP
    function deposit(bool isQuote, uint256 amount) external whenNotPaused nonReentrant isEligibleSender {
        if (isQuote) {
            quoteLpTokenLiquidty += amount;
            quote.safeTransferFrom(msg.sender, address(this), amount);
            quoteLp.deposit(amount, msg.sender);
        } else {
            baseLpTokenLiquidty += amount;
            base.safeTransferFrom(msg.sender, address(this), amount);
            baseLp.deposit(amount, msg.sender);
        }
        emit Deposit(isQuote, amount, msg.sender);
    }

    /// @notice Withdraw
    /// @param isQuote If true user withdraws quote token (else base)
    /// @param amount Amount of LP positions to withdraw
    function withdraw(bool isQuote, uint256 amount) external whenNotPaused nonReentrant isEligibleSender {
        if (isQuote) {
            quoteLpTokenLiquidty -= amount;
            quoteLp.redeem(amount, msg.sender, msg.sender);
        } else {
            baseLpTokenLiquidty -= amount;
            baseLp.redeem(amount, msg.sender, msg.sender);
        }
        emit Withdraw(isQuote, amount, msg.sender);
    }

    /// @notice Buys a zdte option
    /// @param isPut is put option
    /// @param amount Amount of options to long // 1e18
    /// @param strike Strike price // 1e8
    function longOptionPosition(bool isPut, uint256 amount, uint256 strike)
        external
        whenNotPaused
        nonReentrant
        isEligibleSender
        returns (uint256 id)
    {
        if (isPut) {
            validateShortStrike(strike);
        } else {
            validateLongStrike(strike);
        }

        // Calculate premium for ATM option in quote (1e6)
        uint256 premium = calcPremium(strike, amount, 1 days);

        // Calculate opening fees in quote (1e6)
        uint256 openingFees = calcOpeningFees(amount, strike);

        // Transfer fees from user
        quote.transferFrom(msg.sender, address(this), premium + openingFees);

        if (isPut) {
            lockPutLiquidity(amount * strike / AMOUNT_PRICE_TO_USDC_DECIMALS);
        } else {
            lockCallLiquidity(amount);
        }

        // Transfer premium from user
        if (isPut) {
            transferPutFees(openingFees, premium);
        } else {
            transferCallFees(openingFees, premium);
        }

        // Generate zdte position NFT
        id = zdtePositionMinter.mint(msg.sender);

        zdtePositions[id] = ZdtePosition({
            isOpen: true,
            positions: amount,
            longStrike: strike,
            shortStrike: 0,
            longPremium: premium,
            shortPremium: 0,
            fees: openingFees,
            pnl: 0,
            openedAt: block.timestamp,
            expiry: getCurrentExpiry(),
            positionType: isPut ? PositionType.LONG_PUT : PositionType.LONG_CALL
        });

        emit LongOptionPosition(id, amount, strike, msg.sender);
    }

    /// @notice Buys a zdte option
    /// @param isPut is put option
    /// @param longStrike long strike
    /// @param shortStrike short strike
    /// @param amount Amount of options to long // 1e18
    function spreadOptionPosition(bool isPut, uint256 amount, uint256 longStrike, uint256 shortStrike)
        external
        whenNotPaused
        nonReentrant
        isEligibleSender
        returns (uint256 id)
    {
        if (isPut) {
            validateShortStrike(longStrike);
            validateShortStrike(shortStrike);
            require(longStrike > shortStrike, "Invalid strike spread");
        } else {
            validateLongStrike(longStrike);
            validateLongStrike(shortStrike);
            require(longStrike < shortStrike, "Invalid strike spread");
        }

        // Calculate premium for ATM option in quote (1e6)
        uint256 longPremium = calcPremium(longStrike, amount, 1 days);
        uint256 shortPremium = calcPremium(shortStrike, amount, 1 days);

        uint256 markPrice = getMarkPrice();

        // Convert to base asset
        if (!isPut) {
            longPremium = longPremium / markPrice;
            shortPremium = shortPremium / markPrice;
        }

        // Calculate margin required for payouts
        uint256 margin = calcMargin(isPut, longStrike, shortStrike, longPremium, shortPremium) * amount;

        // Calculate opening fees in quote (1e6)
        uint256 openingFees = calcOpeningFees(amount, longStrike + shortStrike);

        // Transfer fees from user
        quote.transferFrom(msg.sender, address(this), longPremium + openingFees);

        if (isPut) {
            lockPutLiquidity(margin * spreadMarginSafety / 100 / AMOUNT_PRICE_TO_USDC_DECIMALS);
        } else {
            lockCallLiquidity(margin * spreadMarginSafety / 100);
        }

        // Transfer premium from user
        if (isPut) {
            transferPutFees(openingFees, shortPremium);
        } else {
            transferCallFees(openingFees, longPremium);
        }

        // Generate zdte position NFT
        id = zdtePositionMinter.mint(msg.sender);

        zdtePositions[id] = ZdtePosition({
            isOpen: true,
            positions: amount,
            longStrike: longStrike,
            shortStrike: shortStrike,
            longPremium: longPremium,
            shortPremium: shortPremium,
            fees: openingFees,
            pnl: 0,
            openedAt: block.timestamp,
            expiry: getCurrentExpiry(),
            positionType: isPut ? PositionType.SPREAD_PUT : PositionType.SPREAD_CALL
        });

        emit SpreadOptionPosition(id, amount, longStrike, shortStrike, msg.sender);
    }

    /// @notice Expires an option position
    /// @param id ID of position
    function expireOptionPosition(uint256 id) external whenNotPaused nonReentrant isEligibleSender {
        canExpire(id);

        uint256 pnlPut;
        uint256 pnlCall;

        ZdtePosition memory position = zdtePositions[id];
        if (position.positionType == PositionType.LONG_PUT || position.positionType == PositionType.SPREAD_PUT) {
            pnlPut = expirePutPosition(id);
        } else {
            pnlCall = expireCallPosition(id);
        }

        zdtePositions[id].isOpen = false;
        emit ExpireOptionPosition(id, pnlPut + pnlCall, msg.sender);
    }

    /*==== INTERNAL METHODS ====*/

    /// @notice Internal function to handle swaps using Uniswap V3 exactIn
    /// @param from Address of the token to sell
    /// @param to Address of the token to buy
    /// @param amountOut Target amount of to token we want to receive
    function _swapExactIn(address from, address to, uint256 amountIn) internal returns (uint256 amountOut) {
        return uniswapV3Router.exactInputSingle(
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

    /// @notice Internal function to validate long strike
    /// @param strike Strike price
    function validateLongStrike(uint256 strike) internal view {
        uint256 markPrice = getMarkPrice();
        require((strike <= (markPrice * (100 + maxOtmPercentage) / 100)) && strike >= markPrice, "Invalid strike");
        require(strike % strikeIncrement == 0, "Invalid strike");
    }

    /// @notice Internal function to validate short strike
    /// @param strike Strike price
    function validateShortStrike(uint256 strike) internal view {
        uint256 markPrice = getMarkPrice();
        require((strike >= (markPrice * (100 - maxOtmPercentage) / 100)) && strike <= markPrice, "Invalid strike");
        require(strike % strikeIncrement == 0, "Invalid strike");
    }

    /// @notice Helper function to transfer call fees
    /// @param openingFees Opening fees
    /// @param premium Premium
    function transferCallFees(uint256 openingFees, uint256 premium) internal {
        uint256 basePremium = _swapExactIn(address(quote), address(base), premium);
        uint256 baseOpeningFees = _swapExactIn(address(quote), address(base), openingFees);
        baseLp.deposit(baseOpeningFees, feeDistributor);
        baseLp.addProceeds(basePremium);
    }

    /// @notice Helper function to transfer put fees
    /// @param openingFees Opening fees
    /// @param premium Premium
    function transferPutFees(uint256 openingFees, uint256 premium) internal {
        quoteLp.deposit(openingFees, feeDistributor);
        quoteLp.addProceeds(premium);
    }

    /// @notice Helper function to lock put liquidity
    /// @param amount Amount of token
    function lockPutLiquidity(uint256 amount) internal {
        require(quoteLp.totalAvailableAssets() >= amount, "Insufficient put liquidity");
        quoteLp.lockLiquidity(amount);
    }

    /// @notice Helper function to lock call liquidity
    /// @param amount Amount of token
    function lockCallLiquidity(uint256 amount) internal {
        require(baseLp.totalAvailableAssets() >= amount, "Insufficient call liquidity");
        baseLp.lockLiquidity(amount);
    }

    /// @notice Helper function to calculate opening fees
    /// @param amount Amount of token
    /// @param strike Strike price
    function calcOpeningFees(uint256 amount, uint256 strike) public view returns (uint256 openingFees) {
        return calcFees(amount * strike / AMOUNT_PRICE_TO_USDC_DECIMALS);
    }

    /// @notice Helper function to expire a put position
    /// @param id ID of position
    function expirePutPosition(uint256 id) internal returns (uint256 pnl) {
        ZdtePosition memory position = zdtePositions[id];
        uint256 unlock = position.positionType == PositionType.LONG_PUT
            ? zdtePositions[id].longStrike * zdtePositions[id].positions / AMOUNT_PRICE_TO_USDC_DECIMALS
            : calcMargin(id) / AMOUNT_PRICE_TO_USDC_DECIMALS;
        pnl = calcPnl(id);
        if (pnl > 0) {
            quoteLp.unlockLiquidity(unlock);
            quoteLp.subtractLoss(pnl);
            quote.transfer(IERC721(zdtePositionMinter).ownerOf(id), pnl);
        } else {
            quoteLp.unlockLiquidity(unlock);
        }
    }

    /// @notice Helper function to expire a call position
    /// @param id ID of position
    function expireCallPosition(uint256 id) internal returns (uint256 pnl) {
        ZdtePosition memory position = zdtePositions[id];
        uint256 unlock = position.positionType == PositionType.LONG_CALL
            ? zdtePositions[id].positions
            : calcMargin(id) / AMOUNT_PRICE_TO_USDC_DECIMALS;
        pnl = calcPnl(id);
        if (pnl > 0) {
            baseLp.unlockLiquidity(unlock);
            baseLp.subtractLoss(pnl);
            base.transfer(IERC721(zdtePositionMinter).ownerOf(id), pnl);
        } else {
            baseLp.unlockLiquidity(unlock);
        }
    }

    /// @notice Helper function to check if a position can be expired
    /// @param id ID of position
    function canExpire(uint256 id) internal view {
        require(zdtePositions[id].isOpen, "Invalid position ID");
        require(zdtePositions[id].expiry <= block.timestamp, "Position must be past expiry time");
    }

    /*==== VIEWS ====*/

    /// @notice External function to return the volatility
    /// @param strike Strike of option
    function getVolatility(uint256 strike) public view returns (uint256 volatility) {
        volatility = uint256(volatilityOracle.getVolatility(strike));
    }

    /// @notice Internal function to calculate premium in quote
    /// @param strike Strike of option
    /// @param amount Amount of option
    /// @param timeToExpiry Time to expiry in seconds
    function calcPremium(
        uint256 strike, // 1e8
        uint256 amount, // 1e18
        uint256 timeToExpiry
    ) public view returns (uint256 premium) {
        uint256 markPrice = getMarkPrice(); // 1e8
        uint256 expiry = block.timestamp + timeToExpiry;
        premium =
            uint256(optionPricing.getOptionPrice(false, expiry, strike, markPrice, getVolatility(strike))) * amount; // ATM options: does not matter if call or put

        // Convert to 6 decimal places (quote asset)
        premium = premium / (AMOUNT_PRICE_TO_USDC_DECIMALS);
    }

    /// @notice Internal function to calculate margin for a spread option position
    /// @param isPut is put option
    /// @param longStrike Long strike price
    /// @param shortStrike Short strike price
    /// @param longPremium Long option premium
    /// @param shortPremium Short option premium
    function calcMargin(
        bool isPut,
        uint256 longStrike,
        uint256 shortStrike,
        uint256 longPremium,
        uint256 shortPremium
    ) internal view returns (uint256 margin) {
        margin = (
            isPut ?
            (longStrike - shortStrike) - longPremium + shortPremium :
            ((shortStrike - longStrike)/ shortStrike) - longPremium + shortPremium
        );
    }

    /// @notice Internal function to calculate fees
    /// @param amount Value of option in USD (ie6)
    function calcFees(uint256 amount) internal view returns (uint256 fees) {
        fees = (amount * feeOpenPosition) / (100 * STRIKE_DECIMALS);
    }

    /// @notice Internal function to calculate margin for a spread option position
    /// @param id ID of position
    function calcMargin(uint256 id) internal view returns (uint256 margin) {
        ZdtePosition memory position = zdtePositions[id];
        margin = calcMargin(
            position.positionType == PositionType.SPREAD_PUT,
            position.longStrike,
            position.shortStrike,
            position.longPremium,
            position.shortPremium
        );
    }

    /// @notice Public function to retrieve price of base asset from oracle
    /// @param price Mark price
    function getMarkPrice() public view returns (uint256 price) {
        price = uint256(priceOracle.getUnderlyingPrice());
    }

    /// @notice Public function to return the next expiry timestamp
    function getCurrentExpiry() public view returns (uint256 expiry) {
        if (block.timestamp > genesisExpiry) {
            // Add one day to the current expiry
            expiry = genesisExpiry + ((((block.timestamp - genesisExpiry) / 1 days) + 1) * 1 days);
        } else {
            // Use the genesis expiry
            expiry = genesisExpiry;
        }
    }

    /// @notice Internal function to calculate pnl
    /// @param id ID of position
    /// @return pnl PNL in quote asset i.e USD (1e6)
    function calcPnl(uint256 id) public view returns (uint256 pnl) {
        uint256 markPrice = getMarkPrice();
        uint256 longStrike = zdtePositions[id].longStrike;
        uint256 shortStrike = zdtePositions[id].shortStrike;
        uint256 positionCount = zdtePositions[id].positions;
        PositionType positionType = zdtePositions[id].positionType;
        if (positionType == PositionType.SPREAD_PUT) {
            pnl = longStrike > markPrice ? positionCount * (longStrike - markPrice) / AMOUNT_PRICE_TO_USDC_DECIMALS : 0;
            pnl -=
                shortStrike > markPrice ? positionCount * (shortStrike - markPrice) / AMOUNT_PRICE_TO_USDC_DECIMALS : 0;
        } else if (positionType == PositionType.SPREAD_CALL) {
            pnl = markPrice > longStrike ? (positionCount * (markPrice - longStrike) / markPrice) : 0;
            pnl -= markPrice > shortStrike ? (positionCount * (markPrice - shortStrike) / markPrice) : 0;
        } else if (positionType == PositionType.LONG_PUT) {
            pnl = longStrike > markPrice ? positionCount * (longStrike - markPrice) / AMOUNT_PRICE_TO_USDC_DECIMALS : 0;
        } else if (positionType == PositionType.LONG_CALL) {
            pnl = markPrice > longStrike ? (positionCount * (markPrice - longStrike) / markPrice) : 0;
        } else {
            revert("Invalid position type");
        }
    }

    /*==== MANAGER METHODS ====*/

    /// @notice Allow only zdte LP contract to claim collateral
    /// @param amount Amount of quote/base assets to transfer
    function claimCollateral(uint256 amount) external {
        require(
            msg.sender == address(quoteLp) || msg.sender == address(baseLp),
            "Only zdte LP contract can claim collateral"
        );
        if (msg.sender == address(quoteLp)) {
            quote.transfer(msg.sender, amount);
        } else if (msg.sender == address(baseLp)) {
            base.transfer(msg.sender, amount);
        }
        emit ClaimCollateral(amount, msg.sender);
    }

    /*==== ADMIN METHODS ====*/

    /// @notice update margin of safety
    /// @param _spreadMarginSafety New margin of safety
    function updateMarginOfSafety(uint256 _spreadMarginSafety) external onlyOwner {
        spreadMarginSafety = _spreadMarginSafety;
    }

    /// @notice Pauses the vault for emergency cases
    /// @dev Can only be called by admin
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the vault
    /// @dev Can only be called by admin
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Add a contract to the whitelist
    /// @dev Can only be called by the owner
    /// @param _contract Address of the contract that needs to be added to the whitelist
    function addToContractWhitelist(address _contract) external onlyOwner {
        _addToContractWhitelist(_contract);
    }

    /// @notice Remove a contract to the whitelist
    /// @dev Can only be called by the owner
    /// @param _contract Address of the contract that needs to be removed from the whitelist
    function removeFromContractWhitelist(address _contract) external onlyOwner {
        _removeFromContractWhitelist(_contract);
    }

    /// @notice Transfers all funds to msg.sender
    /// @dev Can only be called by admin
    /// @param tokens The list of erc20 tokens to withdraw
    /// @param transferNative Whether should transfer the native currency
    function emergencyWithdraw(address[] calldata tokens, bool transferNative) external onlyOwner whenPaused {
        if (transferNative) {
            payable(msg.sender).transfer(address(this).balance);
        }

        for (uint256 i; i < tokens.length;) {
            IERC20Metadata token = IERC20Metadata(tokens[i]);
            token.safeTransfer(msg.sender, token.balanceOf(address(this)));

            unchecked {
                ++i;
            }
        }
    }
}

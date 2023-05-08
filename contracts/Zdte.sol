// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {ZdteLP} from "./token/ZdteLP.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ZdtePositionMinter} from "./positions/ZdtePositionMinter.sol";

import {ContractWhitelist} from "./helpers/ContractWhitelist.sol";

import {IOptionPricing} from "./interface/IOptionPricing.sol";
import {IVolatilityOracle} from "./interface/IVolatilityOracle.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {IUniswapV3Router} from "./interface/IUniswapV3Router.sol";

contract Zdte is ReentrancyGuard, AccessControl, Pausable, ContractWhitelist {
    using SafeERC20 for IERC20Metadata;

    /// @dev Base token
    IERC20Metadata public base;
    /// @dev Quote token
    IERC20Metadata public quote;
    /// @dev zdte Base LP token
    ZdteLP public baseLp;
    /// @dev zdte Quotee LP token
    ZdteLP public quoteLp;
    /// @dev Option pricing
    IOptionPricing public optionPricing;
    /// @dev Volatility oracle
    IVolatilityOracle public volatilityOracle;
    /// @dev Price oracle
    IPriceOracle public priceOracle;
    /// @dev zdte position minter
    ZdtePositionMinter public zdtePositionMinter;
    /// @dev Uniswap V3 router
    IUniswapV3Router public uniswapV3Router;
    /// @dev Fee distributor
    address public feeDistributor;
    /// @dev Fees for opening position
    uint256 public feeOpenPosition = 5000000; // 0.05%
    /// @dev Strike decimals
    uint256 public constant STRIKE_DECIMALS = 1e8;
    /// @dev Convert to USDC decimals
    uint256 internal constant AMOUNT_PRICE_TO_USDC_DECIMALS = (1e18 * 1e8) / 1e6;
    /// @dev Margin decimals
    uint256 public MARGIN_DECIMALS = 100;
    /// @dev Margin of safety to open a spread position
    uint256 public spreadMarginSafety = 300; // 300%
    /// @dev Min volatility to adjust for long strike
    uint256 public minLongStrikeVolAdjust = 5; // 5%
    /// @dev Max volatility to adjust for long strike
    uint256 public maxLongStrikeVolAdjust = 30; // 30%
    /// @dev Max spread positions to expire
    uint256 internal MAX_EXPIRE_BATCH = 30;
    /// @dev Expire delay tolerance
    uint256 public expireDelayTolerance = 5 minutes;
    /// @dev Strike increments
    uint256 public strikeIncrement;
    /// @dev Max OTM % from mark price
    uint256 public maxOtmPercentage;
    /// @dev Genesis expiry timestamp, next day 8am gmt
    uint256 public genesisExpiry;
    /// @dev base token liquidity
    uint256 public baseLpTokenLiquidity;
    /// @dev quote token liquidity
    uint256 public quoteLpTokenLiquidity;
    /// @dev open interest amount
    uint256 public openInterestAmount;
    /// @dev oracle ID
    bytes32 public oracleId;

    /// @dev zdte positions
    mapping(uint256 => ZdtePosition) public zdtePositions;

    /// @dev expiry to info
    mapping(uint256 => ExpiryInfo) public expiryInfo;

    struct ZdtePosition {
        /// @dev Is position open
        bool isOpen;
        /// @dev Is short
        bool isPut;
        /// @dev Is spread
        bool isSpread;
        /// @dev Open position count (in base asset)
        uint256 positions;
        /// @dev Long strike price
        uint256 longStrike;
        /// @dev Short strike price
        uint256 shortStrike;
        /// @dev Long premium for position
        uint256 longPremium;
        /// @dev Short premium for position
        uint256 shortPremium;
        /// @dev Fees for position
        uint256 fees;
        /// @dev Final PNL of position
        int256 pnl;
        /// @dev Opened at timestamp
        uint256 openedAt;
        /// @dev Expiry timestamp
        uint256 expiry;
        /// @dev Margin
        uint256 margin;
        /// @dev Mark price at purchase
        uint256 markPrice;
    }

    struct ExpiryInfo {
        /// @dev Has the epoch begun
        bool begin;
        /// @dev Time when epoch expires
        uint256 expiry;
        /// @dev ID of first position of spread for current epoch
        uint256 startId;
        /// @dev Number of spread positions
        uint256 count;
        /// @dev Settlement price
        uint256 settlementPrice;
        /// @dev Last ID settled for the previous batch
        uint256 lastProccessedId;
    }

    /// @dev Deposit event
    /// @param isQuote isQuote
    /// @param amount amount
    /// @param sender sender
    event Deposit(bool isQuote, uint256 amount, address indexed sender);

    /// @dev Withdraw event
    /// @param isQuote isQuote
    /// @param amount amount
    /// @param sender sender
    event Withdraw(bool isQuote, uint256 amount, address indexed sender);

    /// @dev Spread option position event
    /// @param id id
    /// @param amount amount
    /// @param longStrike longStrike
    /// @param shortStrike shortStrike
    /// @param user user
    event SpreadOptionPosition(
        uint256 id, uint256 amount, uint256 longStrike, uint256 shortStrike, address indexed user
    );

    /// @dev Expire spread position event
    /// @param id id
    /// @param pnl pnl
    /// @param user user
    event SpreadOptionPositionExpired(uint256 id, uint256 pnl, address indexed user);

    /// @dev Expire long option position event
    /// @param expiry expiry
    /// @param lastId lastId
    /// @param user user
    event ExpireSpreads(uint256 expiry, uint256 lastId, address indexed user);

    /// @dev Set settlement price event
    /// @param expiry expiry
    /// @param settlementPrice settlementPrice
    event SettlementPriceSaved(uint256 expiry, uint256 settlementPrice);

    /// @dev Set delay tolerance
    /// @param delay delay
    event ExpireDelayToleranceUpdate(uint256 delay);

    constructor(
        address _base,
        address _quote,
        address _optionPricing,
        address _volatilityOracle,
        address _priceOracle,
        address _uniswapV3Router,
        address _feeDistributor,
        uint256 _strikeIncrement,
        uint256 _maxOtmPercentage,
        uint256 _genesisExpiry,
        string memory _oracleId
    ) {
        require(_base != address(0), "Invalid base token");
        require(_quote != address(0), "Invalid quote token");
        require(_optionPricing != address(0), "Invalid option pricing");
        require(_volatilityOracle != address(0), "Invalid volatility oracle");
        require(_priceOracle != address(0), "Invalid price oracle");
        require(_uniswapV3Router != address(0), "Invalid router");
        require(_feeDistributor != address(0), "Invalid fee distributor");

        require(_strikeIncrement > 0, "Invalid strike increment");
        require(_maxOtmPercentage > 0, "Invalid max OTM %");
        require(_genesisExpiry > block.timestamp, "Invalid genesis expiry");

        base = IERC20Metadata(_base);
        quote = IERC20Metadata(_quote);
        optionPricing = IOptionPricing(_optionPricing);
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        priceOracle = IPriceOracle(_priceOracle);
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);

        feeDistributor = _feeDistributor;
        strikeIncrement = _strikeIncrement;
        maxOtmPercentage = _maxOtmPercentage;
        genesisExpiry = _genesisExpiry;
        oracleId = keccak256(abi.encodePacked(_oracleId));

        zdtePositionMinter = new ZdtePositionMinter();

        base.approve(address(uniswapV3Router), type(uint256).max);
        quote.approve(address(uniswapV3Router), type(uint256).max);

        quoteLp = new ZdteLP(address(this), address(quote), quote.symbol());
        baseLp = new ZdteLP(address(this), address(base), base.symbol());

        quote.approve(address(quoteLp), type(uint256).max);
        base.approve(address(baseLp), type(uint256).max);

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

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

    /// @notice Deposit assets
    /// @param isQuote If true user deposits quote token (else base)
    /// @param amount Amount of quote asset to deposit to LP
    function deposit(bool isQuote, uint256 amount) external whenNotPaused nonReentrant isEligibleSender {
        if (isQuote) {
            quoteLpTokenLiquidity += amount;
            quote.transferFrom(msg.sender, address(this), amount);
            quoteLp.deposit(amount, msg.sender);
        } else {
            baseLpTokenLiquidity += amount;
            base.transferFrom(msg.sender, address(this), amount);
            baseLp.deposit(amount, msg.sender);
        }
        emit Deposit(isQuote, amount, msg.sender);
    }

    /// @notice Withdraw
    /// @param isQuote If true user withdraws quote token (else base)
    /// @param amount Amount of LP positions to withdraw
    function withdraw(bool isQuote, uint256 amount) external whenNotPaused nonReentrant isEligibleSender {
        if (isQuote) {
            quoteLpTokenLiquidity -= amount;
            quoteLp.redeem(amount, msg.sender, msg.sender);
        } else {
            baseLpTokenLiquidity -= amount;
            baseLp.redeem(amount, msg.sender, msg.sender);
        }
        emit Withdraw(isQuote, amount, msg.sender);
    }

    /// @notice Sets up a zdte spread option position
    /// @param isPut is put spread
    /// @param amount Amount of options to long // 1e18
    /// @param longStrike Long Strike price // 1e8
    /// @param shortStrike Short Strike price // 1e8
    function spreadOptionPosition(bool isPut, uint256 amount, uint256 longStrike, uint256 shortStrike)
        external
        whenNotPaused
        nonReentrant
        isEligibleSender
        returns (uint256 id)
    {
        uint256 markPrice = getMarkPrice();
        require(
            (
                (
                    isPut && ((longStrike >= ((markPrice * (100 - maxOtmPercentage)) / 100)) && longStrike <= markPrice)
                        && longStrike > shortStrike
                )
                    || (
                        !isPut
                            && ((longStrike <= ((markPrice * (100 + maxOtmPercentage)) / 100)) && longStrike >= markPrice)
                            && longStrike < shortStrike
                    )
            ) && longStrike % strikeIncrement == 0,
            "Invalid long strike"
        );
        require(
            (
                (
                    isPut
                        && ((shortStrike >= ((markPrice * (100 - maxOtmPercentage)) / 100)) && shortStrike <= markPrice)
                        && shortStrike < longStrike
                )
                    || (
                        !isPut
                            && ((shortStrike <= ((markPrice * (100 + maxOtmPercentage)) / 100)) && shortStrike >= markPrice)
                            && shortStrike > longStrike
                    )
            ) && shortStrike % strikeIncrement == 0,
            "Invalid short strike"
        );

        // Calculate margin required for payouts
        uint256 margin = (calcMargin(isPut, longStrike, shortStrike) * amount) / 1 ether;
        // utilisation range from 0 to 10000, when it full use it is 10000
        uint256 utilisation = 0;

        if (isPut) {
            require(quoteLp.totalAvailableAssets() >= margin, "Insufficient liquidity");
            quoteLp.lockLiquidity(margin);
            utilisation = ((quoteLp.totalAssets() - quoteLp.totalAvailableAssets()) * 10000) / quoteLp.totalAssets();
        } else {
            require(baseLp.totalAvailableAssets() >= margin, "Insufficient liquidity");
            baseLp.lockLiquidity(margin);
            utilisation = ((baseLp.totalAssets() - baseLp.totalAvailableAssets()) * 10000) / baseLp.totalAssets();
        }

        // Calculate premium for long option in quote (1e6)
        uint256 vol = getVolatility(longStrike);
        // Adjust longStrikeVol in function of utilisation
        vol = vol + (vol * minLongStrikeVolAdjust) / 100
            + (vol * utilisation * (maxLongStrikeVolAdjust - minLongStrikeVolAdjust)) / (100 * 10000);
        uint256 longPremium = calcPremiumWithVol(isPut, markPrice, longStrike, vol, amount);

        // Calculate premium for short option in quote (1e6)
        // No adjust vol for shortStrikeVol
        vol = getVolatility(shortStrike);
        uint256 shortPremium = calcPremiumWithVol(isPut, markPrice, shortStrike, vol, amount);

        uint256 premium = longPremium - shortPremium;
        require(premium > 0, "Premium must be greater than 0");

        // Calculate opening fees in quote (1e6)
        uint256 openingFees = calcFees((amount * (longStrike + shortStrike)) / AMOUNT_PRICE_TO_USDC_DECIMALS);

        // We transfer premium + fees from user
        quote.transferFrom(msg.sender, address(this), premium + openingFees);

        // Transfer fees to fee distributor
        if (isPut) {
            quoteLp.deposit(openingFees, feeDistributor);
            quoteLp.addProceeds(premium);
        } else {
            uint256 basePremium = _swapExactIn(address(quote), address(base), premium);
            uint256 baseOpeningFees = _swapExactIn(address(quote), address(base), openingFees);
            baseLp.deposit(baseOpeningFees, feeDistributor);
            baseLp.addProceeds(basePremium);
        }

        // Generate zdte position NFT
        id = zdtePositionMinter.mint(msg.sender);

        zdtePositions[id] = ZdtePosition({
            isOpen: true,
            isPut: isPut,
            isSpread: true,
            positions: amount,
            longStrike: longStrike,
            shortStrike: shortStrike,
            longPremium: longPremium,
            shortPremium: shortPremium,
            fees: openingFees,
            pnl: 0,
            openedAt: block.timestamp,
            expiry: getCurrentExpiry(),
            margin: margin,
            markPrice: markPrice
        });

        openInterestAmount += amount;
        _recordSpreadCount(id);

        emit SpreadOptionPosition(id, amount, longStrike, shortStrike, msg.sender);
    }

    /// @notice Expires an spread option position
    /// @param id ID of position
    function expireSpreadOptionPosition(uint256 id) public whenNotPaused nonReentrant isEligibleSender {
        require(zdtePositions[id].isOpen, "Invalid position ID");
        require(zdtePositions[id].isSpread, "Must be a spread option position");

        require(zdtePositions[id].expiry <= block.timestamp, "Position must be past expiry time");

        uint256 pnl = calcPnl(id);
        uint256 margin = zdtePositions[id].margin;

        if (pnl > 0) {
            if (zdtePositions[id].isPut) {
                quoteLp.unlockLiquidity(margin);
                quoteLp.subtractLoss(pnl);
                quote.transfer(IERC721(zdtePositionMinter).ownerOf(id), pnl);
            } else {
                baseLp.unlockLiquidity(margin);

                ZdtePosition memory zp = zdtePositions[id];
                uint256 settlementPrice = expiryInfo[zp.expiry].settlementPrice;
                uint256 pnlInBase = (pnl * AMOUNT_PRICE_TO_USDC_DECIMALS) / settlementPrice;
                require(margin >= pnlInBase, "pnl in Base cant be greater than the reserved margin");

                baseLp.subtractLoss(pnlInBase);

                uint256 quotePnL = _swapExactIn(address(base), address(quote), pnlInBase);

                quote.transfer(IERC721(zdtePositionMinter).ownerOf(id), quotePnL);
            }
        } else if (zdtePositions[id].isPut) {
            quoteLp.unlockLiquidity(margin);
        } else {
            baseLp.unlockLiquidity(margin);
        }

        openInterestAmount -= zdtePositions[id].positions;
        zdtePositions[id].isOpen = false;
        emit SpreadOptionPositionExpired(id, pnl, msg.sender);
    }

    /// @notice Helper function to save settlement price
    /// @return did settlement price save successfully
    function saveSettlementPrice() public whenNotPaused returns (bool) {
        uint256 prevExpiry = getPrevExpiry();
        require(block.timestamp < prevExpiry + expireDelayTolerance, "Expiry is past tolerance");
        require(_saveSettlementPrice(prevExpiry, getMarkPrice()), "Failed to save settlement price");
        return true;
    }

    /**
     * @notice Helper function for admin to save settlement price
     * @param expiry Expiry to set settlement price
     * @param settlementPrice Settlement price
     * @return did settlement price save successfully
     */
    function saveSettlementPrice(uint256 expiry, uint256 settlementPrice)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        returns (bool)
    {
        require(_saveSettlementPrice(expiry, settlementPrice), "Failed to save settlement price");
        return true;
    }

    /**
     * @notice Helper function set settlement price at expiry
     * @param expiry Expiry to set settlement price
     * @param settlementPrice Settlement price
     * @return did settlement price save successfully
     */
    function _saveSettlementPrice(uint256 expiry, uint256 settlementPrice) internal whenNotPaused returns (bool) {
        require(expiry < block.timestamp, "Expiry must be in the past");
        require(expiryInfo[expiry].settlementPrice == 0, "Settlement price saved");
        expiryInfo[expiry].settlementPrice = settlementPrice;
        emit SettlementPriceSaved(expiry, settlementPrice);
        return true;
    }

    /// @notice Helper function expire prev epoch
    /// @return did prev epoch expire successfully
    function expirePrevEpochSpreads() public whenNotPaused returns (bool) {
        uint256 prevExpiry = getPrevExpiry();
        ExpiryInfo memory ei = expiryInfo[prevExpiry];
        uint256 startId = ei.lastProccessedId == 0 ? ei.startId : ei.lastProccessedId;
        require(expireSpreads(prevExpiry, startId), "failed to expire spreads");
        return true;
    }

    /**
     * @notice Helper function expire prev epoch
     * @param expiry Expiry to set settlement price
     * @param startId First ID to expire
     * @return did spreads expire successfully
     */
    function expireSpreads(uint256 expiry, uint256 startId) public whenNotPaused returns (bool) {
        require(expiryInfo[expiry].settlementPrice != 0, "Settlement price not saved");
        ExpiryInfo memory info = expiryInfo[expiry];
        if (info.count == 0) {
            return false;
        }
        uint256 numToProcess = Math.min(info.count, MAX_EXPIRE_BATCH);
        uint256 endIdx = startId + numToProcess;
        while (startId < endIdx) {
            if (zdtePositions[startId].isOpen && zdtePositions[startId].isSpread) {
                expireSpreadOptionPosition(startId);
            }
            startId++;
        }
        expiryInfo[expiry].count -= numToProcess;
        expiryInfo[expiry].lastProccessedId = startId;
        emit ExpireSpreads(expiry, startId, msg.sender);
        return true;
    }

    /// @notice Allow only zdte LP contract to claim collateral
    /// @param amount Amount of quote/base assets to transfer
    function claimCollateral(uint256 amount) public {
        require(
            msg.sender == address(quoteLp) || msg.sender == address(baseLp),
            "Only zdte LP contract can claim collateral"
        );
        if (msg.sender == address(quoteLp)) {
            quote.transfer(msg.sender, amount);
        } else if (msg.sender == address(baseLp)) {
            base.transfer(msg.sender, amount);
        }
    }

    /**
     * @notice External function to return the volatility
     * @param strike Strike of option
     * @return volatility
     */
    function getVolatility(uint256 strike) public view returns (uint256 volatility) {
        volatility = uint256(volatilityOracle.getVolatility(oracleId, getCurrentExpiry(), strike));
    }

    /**
     * @notice External function to return the volatility
     * @param strike Strike of option
     * @param expiry Expiry of option
     * @return volatility
     */
    function getVolatilityWithExpiry(uint256 strike, uint256 expiry) public view returns (uint256 volatility) {
        volatility = uint256(volatilityOracle.getVolatility(oracleId, expiry, strike));
    }

    /**
     * @notice External function to validate spread position
     * @param isPut is put spread
     * @param amount Amount of options to long // 1e18
     * @param longStrike Long Strike price // 1e8
     * @param shortStrike Short Strike price // 1e8
     * @return is condition valid to open spread
     */
    function canOpenSpreadPosition(bool isPut, uint256 amount, uint256 longStrike, uint256 shortStrike)
        external
        view
        returns (bool)
    {
        uint256 margin = (calcMargin(isPut, longStrike, shortStrike) * amount) / 1 ether;
        return isPut ? quoteLp.totalAvailableAssets() >= margin : baseLp.totalAvailableAssets() >= margin;
    }

    /**
     * @notice Public function to calculate premium in quote
     * @param isPut if calc premium for put
     * @param strike Strike of option
     * @param amount Amount of option
     * @return premium
     */
    function calcPremium(
        bool isPut,
        uint256 strike, // 1e8
        uint256 amount
    ) public view returns (uint256 premium) {
        uint256 markPrice = getMarkPrice(); // 1e8
        premium = uint256(
            optionPricing.getOptionPrice(isPut, getCurrentExpiry(), strike, markPrice, getVolatility(strike))
        ) * amount; // ATM options: does not matter if call or put
        // Convert to 6 decimal places (quote asset)
        premium = premium / AMOUNT_PRICE_TO_USDC_DECIMALS;
    }

    /**
     * @notice Public function to calculate premium in quote
     * @param isPut if calc premium for put
     * @param strike Strike of option
     * @param volatility Vol
     * @param amount Amount of option
     * @return premium
     */
    function calcPremiumWithVol(
        bool isPut,
        uint256 markPrice,
        uint256 strike, // 1e8
        uint256 volatility,
        uint256 amount
    ) public view returns (uint256 premium) {
        premium =
            uint256(optionPricing.getOptionPrice(isPut, getCurrentExpiry(), strike, markPrice, volatility)) * amount; // ATM options: does not matter if call or put
        // Convert to 6 decimal places (quote asset)
        premium = premium / AMOUNT_PRICE_TO_USDC_DECIMALS;
    }

    /**
     * @notice Public function to calculate premium in quote
     * @param isPut if calc premium for put
     * @param strike Strike of option
     * @param amount Amount of option
     * @return premium
     */
    function calcPremiumCustom(
        bool isPut,
        uint256 strike, // 1e8
        uint256 amount
    ) public view returns (uint256 premium) {
        // Calculate premium for long option in quote (1e6)
        uint256 vol = getVolatility(strike);

        uint256 utilisation = 0;
        if (isPut && quoteLp.totalAssets() > 0) {
            utilisation = ((quoteLp.totalAssets() - quoteLp.totalAvailableAssets()) * 10000) / quoteLp.totalAssets();
        } else if (!isPut && baseLp.totalAssets() > 0) {
            utilisation = ((baseLp.totalAssets() - baseLp.totalAvailableAssets()) * 10000) / baseLp.totalAssets();
        }

        // Adjust longStrikeVol in function of utilisation
        vol = vol + (vol * minLongStrikeVolAdjust) / 100
            + (vol * utilisation * (maxLongStrikeVolAdjust - minLongStrikeVolAdjust)) / (100 * 10000);
        premium = calcPremiumWithVol(isPut, getMarkPrice(), strike, vol, amount);
    }

    /**
     * @notice Internal function to calculate premium in quote
     * @param strike Strike of option
     * @param amount Amount of option
     * @return premium
     */
    function calcOpeningFees(
        uint256 strike, // 1e8
        uint256 amount // 1e18
    ) public view returns (uint256 premium) {
        return calcFees((amount * strike) / AMOUNT_PRICE_TO_USDC_DECIMALS);
    }

    /**
     * @notice Internal function to calculate margin for a spread option position
     * @param id ID of position
     * @return margin
     */
    function calcMargin(uint256 id) internal view returns (uint256 margin) {
        ZdtePosition memory position = zdtePositions[id];
        margin = calcMargin(position.isPut, position.longStrike, position.shortStrike);
    }

    /**
     * @notice Internal function to calculate margin for a spread option position
     * @param isPut is put option
     * @param longStrike Long strike price
     * @param shortStrike Short strike price
     */
    function calcMargin(bool isPut, uint256 longStrike, uint256 shortStrike) public view returns (uint256 margin) {
        margin = (isPut ? (longStrike - shortStrike) / 100 : ((shortStrike - longStrike) * 1 ether) / shortStrike);
        margin = (margin * spreadMarginSafety) / MARGIN_DECIMALS;
    }

    /**
     * @notice Internal function to calculate fees
     *  @param amount Value of option in USD (ie6)
     *  @return fees
     */
    function calcFees(uint256 amount) public view returns (uint256 fees) {
        fees = (amount * feeOpenPosition) / (100 * STRIKE_DECIMALS);
    }

    /**
     * @notice Internal function to calculate pnl
     * @param id ID of position
     * @return pnl PNL in quote asset i.e USD (1e6)
     */
    function calcPnl(uint256 id) public view returns (uint256 pnl) {
        ZdtePosition memory zp = zdtePositions[id];
        uint256 markPrice = zp.expiry < block.timestamp ? expiryInfo[zp.expiry].settlementPrice : getMarkPrice();
        uint256 longStrike = zdtePositions[id].longStrike;
        uint256 shortStrike = zdtePositions[id].shortStrike;
        if (zdtePositions[id].isSpread) {
            if (zdtePositions[id].isPut) {
                pnl = longStrike > markPrice
                    ? ((zdtePositions[id].positions) * (longStrike - markPrice)) / AMOUNT_PRICE_TO_USDC_DECIMALS
                    : 0;
                pnl -= shortStrike > markPrice
                    ? ((zdtePositions[id].positions) * (shortStrike - markPrice)) / AMOUNT_PRICE_TO_USDC_DECIMALS
                    : 0;
            } else {
                pnl = markPrice > longStrike
                    ? ((zdtePositions[id].positions * (markPrice - longStrike)) / AMOUNT_PRICE_TO_USDC_DECIMALS)
                    : 0;
                pnl -= markPrice > shortStrike
                    ? ((zdtePositions[id].positions * (markPrice - shortStrike)) / AMOUNT_PRICE_TO_USDC_DECIMALS)
                    : 0;
            }
        } else {
            if (zdtePositions[id].isPut) {
                pnl = longStrike > markPrice
                    ? ((zdtePositions[id].positions) * (longStrike - markPrice)) / AMOUNT_PRICE_TO_USDC_DECIMALS
                    : 0;
            } else {
                pnl = markPrice > longStrike
                    ? ((zdtePositions[id].positions * (markPrice - longStrike)) / AMOUNT_PRICE_TO_USDC_DECIMALS)
                    : 0;
            }
        }
    }

    /// @notice Internal function to record expiry info
    /// @param positionId Position ID
    function _recordSpreadCount(uint256 positionId) internal {
        uint256 expiry = getCurrentExpiry();
        if (!expiryInfo[expiry].begin) {
            expiryInfo[expiry] = ExpiryInfo({
                expiry: expiry,
                begin: true,
                lastProccessedId: 0,
                startId: positionId,
                count: 1,
                settlementPrice: 0
            });
        } else {
            expiryInfo[expiry].count++;
        }
    }

    /// @notice Public function to retrieve price of base asset from oracle
    /// @return price
    function getMarkPrice() public view returns (uint256 price) {
        price = uint256(priceOracle.getUnderlyingPrice());
    }

    /// @notice Public function to return the next expiry timestamp
    /// @return expiry
    function getCurrentExpiry() public view returns (uint256 expiry) {
        if (block.timestamp > genesisExpiry) {
            expiry = genesisExpiry + ((((block.timestamp - genesisExpiry) / 1 days) + 1) * 1 days);
        } else {
            expiry = genesisExpiry;
        }
    }

    /// @notice Public function to return the prev expiry timestamp
    /// @return expiry
    function getPrevExpiry() public view returns (uint256 expiry) {
        if (getCurrentExpiry() == genesisExpiry) {
            expiry = 0;
        } else {
            expiry = getCurrentExpiry() - 1 days;
        }
    }

    /// @notice Updates the delay tolerance for the expiry epoch function
    /// @dev Can only be called by the owner
    function updateExpireDelayTolerance(uint256 _expireDelayTolerance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        expireDelayTolerance = _expireDelayTolerance;
        emit ExpireDelayToleranceUpdate(_expireDelayTolerance);
    }

    /// @notice update max otm percentage
    /// @param _maxOtmPercentage New margin of safety
    function updateMaxOtmPercentage(uint256 _maxOtmPercentage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxOtmPercentage = _maxOtmPercentage;
    }

    /// @notice update min long vol adjust
    /// @param _minLongStrikeVolAdjust New margin of safety
    function updateMinLongStrikeVolAdjust(uint256 _minLongStrikeVolAdjust) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minLongStrikeVolAdjust = _minLongStrikeVolAdjust;
    }

    /// @notice update max long vol adjust
    /// @param _maxLongStrikeVolAdjust New margin of safety
    function updateMaxLongStrikeVolAdjust(uint256 _maxLongStrikeVolAdjust) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxLongStrikeVolAdjust = _maxLongStrikeVolAdjust;
    }

    /// @notice update margin of safety
    /// @param _spreadMarginSafety New margin of safety
    function updateMarginOfSafety(uint256 _spreadMarginSafety) external onlyRole(DEFAULT_ADMIN_ROLE) {
        spreadMarginSafety = _spreadMarginSafety;
    }

    /// @notice update oracleId
    /// @param _oracleId Oracle Id
    function updateOracleId(string memory _oracleId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracleId = keccak256(abi.encodePacked(_oracleId));
    }

    /// @notice Pauses the vault for emergency cases
    /// @dev Can only be called by admin
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the vault
    /// @dev Can only be called by admin
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Add a contract to the whitelist
    /// @dev Can only be called by the owner
    /// @param _contract Address of the contract that needs to be added to the whitelist
    function addToContractWhitelist(address _contract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addToContractWhitelist(_contract);
    }

    /// @notice Remove a contract to the whitelist
    /// @dev Can only be called by the owner
    /// @param _contract Address of the contract that needs to be removed from the whitelist
    function removeFromContractWhitelist(address _contract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _removeFromContractWhitelist(_contract);
    }

    /// @notice Transfers all funds to msg.sender
    /// @dev Can only be called by admin
    /// @param tokens The list of erc20 tokens to withdraw
    /// @param transferNative Whether should transfer the native currency
    function emergencyWithdraw(address[] calldata tokens, bool transferNative)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
    {
        if (transferNative) {
            payable(msg.sender).transfer(address(this).balance);
        }

        for (uint256 i; i < tokens.length;) {
            IERC20Metadata token = IERC20Metadata(tokens[i]);
            token.transfer(msg.sender, token.balanceOf(address(this)));

            unchecked {
                ++i;
            }
        }
    }
}

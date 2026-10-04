// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FundingLib } from "../lib/FundingLib.sol";
import { IWavvyAMM } from "../interfaces/IWavvyAMM.sol";
import { IRiskManager } from "../interfaces/IRiskManager.sol";
import { WavvyMath } from "../lib/WavvyMath.sol";

/// @notice Per-market virtual AMM plus the cumulative funding index.
///
/// Reserves are virtual: the AMM tracks a base reserve (synthetic metric units) and a quote reserve (USD), both wad.
/// The constant product K = base * quote fixes the price curve, so opening a long moves the base
/// reserve down and the price up, and opening a short does the reverse. Mark price is quote / base.
///
/// Funding accrues per block as
/// clamp(k * (mark - index) / index, -maxRate, +maxRate)
/// and accumulates into a per-market growth index. Positions only store their
/// last checkpoint, so settlement is a single subtraction.
///
/// Every limit comes from the risk manager, read on each state-changing call.
contract WavvyAMM is AccessControl, IWavvyAMM {
    bytes32 public constant HOUSE_ROLE = keccak256("HOUSE_ROLE");
    bytes32 public constant MARKET_ADMIN_ROLE = keccak256("MARKET_ADMIN_ROLE");

    struct AMMMarket {
        uint256 baseReserve;
        uint256 quoteReserve;
        FundingLib.State funding;
        uint256 openInterestLong;
        uint256 openInterestShort;
        bool exists;
    }

    IRiskManager public immutable risk;

    mapping(uint256 => AMMMarket) private _markets;

    error UnknownMarket();
    error MarketExists();
    error InvalidMarketParams();
    error MarketPaused();
    error ZeroAmount();
    error ReserveDepleted();
    error OpenInterestCapExceeded();
    error OpenInterestUnderflow();

    event MarketCreated(uint256 indexed marketId, uint256 initialPrice, uint256 virtualDepth);
    event Trade(uint256 indexed marketId, bool isLong, bool isOpen, uint256 size, uint256 price);
    event FundingAccrued(uint256 indexed marketId, int256 growth, uint256 blockNumber);

    constructor(IRiskManager risk_, address admin) {
        risk = risk_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Create a market. `virtualDepth` is the initial base reserve:
    /// smaller depth means more price impact per unit of size.
    function createMarket(uint256 marketId, uint256 initialPrice, uint256 virtualDepth)
        external
        onlyRole(MARKET_ADMIN_ROLE)
    {
        AMMMarket storage market = _markets[marketId];
        if (market.exists) revert MarketExists();
        if (initialPrice == 0 || virtualDepth == 0) revert InvalidMarketParams();
        market.baseReserve = virtualDepth;
        market.quoteReserve = WavvyMath.mulWad(virtualDepth, initialPrice);
        market.funding.lastBlock = block.number;
        market.exists = true;
        emit MarketCreated(marketId, initialPrice, virtualDepth);
    }

    /// @inheritdoc IWavvyAMM
    function openTrade(uint256 marketId, bool isLong, uint256 size, uint256 indexPrice)
        external
        onlyRole(HOUSE_ROLE)
        returns (uint256 entryPrice)
    {
        AMMMarket storage market = _markets[marketId];
        if (!market.exists) revert UnknownMarket();
        if (risk.isMarketPaused(marketId)) revert MarketPaused();
        if (size == 0) revert ZeroAmount();

        _accrue(market, marketId, indexPrice);
        entryPrice = _execute(market, isLong, size, true);

        uint256 notional = WavvyMath.mulWad(size, entryPrice);
        uint256 currentOpenInterest = WavvyMath.mulWad(market.openInterestLong + market.openInterestShort, entryPrice);
        if (currentOpenInterest + notional > risk.openInterestCap(marketId)) revert OpenInterestCapExceeded();

        if (isLong) {
            market.openInterestLong += size;
        } else {
            market.openInterestShort += size;
        }

        emit Trade(marketId, isLong, true, size, entryPrice);
    }

    /// @inheritdoc IWavvyAMM
    function closeTrade(uint256 marketId, bool isLong, uint256 size, uint256 indexPrice)
        external
        onlyRole(HOUSE_ROLE)
        returns (uint256 exitPrice)
    {
        AMMMarket storage market = _markets[marketId];
        if (!market.exists) revert UnknownMarket();
        if (size == 0) revert ZeroAmount();

        _accrue(market, marketId, indexPrice);
        exitPrice = _execute(market, isLong, size, false);

        if (isLong) {
            if (market.openInterestLong < size) revert OpenInterestUnderflow();
            market.openInterestLong -= size;
        } else {
            if (market.openInterestShort < size) revert OpenInterestUnderflow();
            market.openInterestShort -= size;
        }

        emit Trade(marketId, isLong, false, size, exitPrice);
    }

/// @notice Advance the cumulative funding index to the current block.
    function accrueFunding(uint256 marketId, uint256 indexPrice) external onlyRole(HOUSE_ROLE) returns (int256) {
        AMMMarket storage market = _markets[marketId];
        if (!market.exists) revert UnknownMarket();
        return _accrue(market, marketId, indexPrice);
    }

    /// @notice Average execution price for a trade without mutating state.
    /// The house uses it to size positions against price impact.
    function previewTrade(uint256 marketId, bool isLong, uint256 size, bool isOpen)
        external
        view
        returns (uint256 price)
    {
        AMMMarket storage market = _markets[marketId];
        if (!market.exists) revert UnknownMarket();
        if (size == 0) revert ZeroAmount();
        bool traderBuysBase = isOpen == isLong;
        if (traderBuysBase) {
            if (size >= market.baseReserve) revert ReserveDepleted();
            uint256 newBase = market.baseReserve - size;
            uint256 newQuote = WavvyMath.mulDivFloor(market.baseReserve, market.quoteReserve, newBase);
            price = WavvyMath.divWad(newQuote - market.quoteReserve, size);
        } else {
            uint256 newBase = market.baseReserve + size;
            uint256 newQuote = WavvyMath.mulDivFloor(market.baseReserve, market.quoteReserve, newBase);
            price = WavvyMath.divWad(market.quoteReserve - newQuote, size);
        }
    }

    function markPrice(uint256 marketId) external view returns (uint256) {
        AMMMarket storage market = _markets[marketId];
        if (!market.exists) revert UnknownMarket();
        return WavvyMath.divWad(market.quoteReserve, market.baseReserve);
    }

    function fundingGrowth(uint256 marketId) external view returns (int256) {
        return _markets[marketId].funding.growth;
    }

    function openInterest(uint256 marketId) external view returns (uint256 long, uint256 short) {
        AMMMarket storage market = _markets[marketId];
        return (market.openInterestLong, market.openInterestShort);
    }

    function marketExists(uint256 marketId) external view returns (bool) {
        return _markets[marketId].exists;
    }

    function getMarket(uint256 marketId) external view returns (Market memory) {
        AMMMarket storage market = _markets[marketId];
        return Market({
            baseReserve: market.baseReserve,
            quoteReserve: market.quoteReserve,
            fundingGrowth: market.funding.growth,
            lastFundingBlock: market.funding.lastBlock,
            openInterestLong: market.openInterestLong,
            openInterestShort: market.openInterestShort,
            exists: market.exists
        });
    }

    /// @dev Constant product trade. `traderBuysBase` is true when the trader
    /// opens a long or closes a short.
    function _execute(AMMMarket storage market, bool isLong, uint256 size, bool isOpen)
        internal
        returns (uint256 price)
    {
        bool traderBuysBase = isOpen == isLong;
        if (traderBuysBase) {
            if (size >= market.baseReserve) revert ReserveDepleted();
            uint256 newBase = market.baseReserve - size;
            uint256 newQuote = WavvyMath.mulDivFloor(market.baseReserve, market.quoteReserve, newBase);
            uint256 quotePaid = newQuote - market.quoteReserve;
            market.baseReserve = newBase;
            market.quoteReserve = newQuote;
            price = WavvyMath.divWad(quotePaid, size);
        } else {
            uint256 newBase = market.baseReserve + size;
            uint256 newQuote = WavvyMath.mulDivFloor(market.baseReserve, market.quoteReserve, newBase);
            uint256 quoteReturned = market.quoteReserve - newQuote;
            market.baseReserve = newBase;
            market.quoteReserve = newQuote;
            price = WavvyMath.divWad(quoteReturned, size);
        }
    }

    function _accrue(AMMMarket storage market, uint256 marketId, uint256 indexPrice) internal returns (int256 growth) {
        uint256 mark = WavvyMath.divWad(market.quoteReserve, market.baseReserve);
        growth = FundingLib.accrue(
            market.funding,
            mark,
            indexPrice,
            risk.fundingCoefficient(marketId),
            risk.maxFundingRatePerBlock(marketId),
            block.number
        );
        emit FundingAccrued(marketId, growth, block.number);
    }
}
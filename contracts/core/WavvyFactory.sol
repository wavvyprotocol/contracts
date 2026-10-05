// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IWavvyAMM } from "../interfaces/IWavvyAMM.sol";
import { IWavvyFactory } from "../interfaces/IWavvyFactory.sol";
import { IWavvyHouse } from "../interfaces/IWavvyHouse.sol";

/// @notice Curated market registry. Markets are created by the protocol, not permissionlessly: creation is role gated and each market records its type, metric, and the creators who share the fee.
///
/// Creating a market also creates the vAMM state and points the house at the market's price source, so a registered market is immediately tradeable.
contract WavvyFactory is AccessControl, IWavvyFactory {
    bytes32 public constant MARKET_ADMIN_ROLE = keccak256("MARKET_ADMIN_ROLE");

    uint8 public constant TYPE_SINGLE_NAME = 0;
    uint8 public constant TYPE_INDEX = 1;

    uint8 public constant PRICE_SOURCE_METRIC = 0;
    uint8 public constant PRICE_SOURCE_INDEX = 1;

    struct Market {
        uint8 marketType;
        bytes32 metricId;
        bytes32[] creatorIds;
        bool exists;
    }

    IWavvyAMM public immutable amm;
    IWavvyHouse public immutable house;

    mapping(uint256 => Market) private _markets;

    error MarketExists();
    error InvalidMarketParams();

    event MarketCreated(
        uint256 indexed marketId,
        uint8 marketType,
        bytes32 metricId,
        uint256 initialPrice,
        uint256 virtualDepth,
        bytes32[] creatorIds
    );

    constructor(IWavvyAMM amm_, IWavvyHouse house_, address admin) {
        amm = amm_;
        house = house_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Register a market and spin up its trading state.
    /// `marketType`: 0 single-name, 1 index. Single-name markets list one creator, index markets list every constituent so the fee splits equally.
    function createMarket(
        uint256 marketId,
        uint8 marketType,
        bytes32 metricId,
        bytes32[] calldata creatorIds,
        uint256 initialPrice,
        uint256 virtualDepth
    ) external onlyRole(MARKET_ADMIN_ROLE) {
        Market storage market = _markets[marketId];
        if (market.exists) revert MarketExists();
        if (marketType > TYPE_INDEX || initialPrice == 0 || virtualDepth == 0) revert InvalidMarketParams();
        if (marketType == TYPE_SINGLE_NAME && creatorIds.length != 1) revert InvalidMarketParams();
        if (marketType == TYPE_INDEX && creatorIds.length == 0) revert InvalidMarketParams();
        if (metricId == bytes32(0)) revert InvalidMarketParams();

        market.marketType = marketType;
        market.metricId = metricId;
        market.creatorIds = creatorIds;
        market.exists = true;

        uint8 priceSource = marketType == TYPE_INDEX ? PRICE_SOURCE_INDEX : PRICE_SOURCE_METRIC;

        amm.createMarket(marketId, initialPrice, virtualDepth);
        house.setMarketPriceSource(marketId, priceSource, metricId);

        emit MarketCreated(marketId, marketType, metricId, initialPrice, virtualDepth, creatorIds);
    }

    function marketExists(uint256 marketId) external view override returns (bool) {
        return _markets[marketId].exists;
    }

    function marketTypeOf(uint256 marketId) external view override returns (uint8) {
        return _markets[marketId].marketType;
    }

    function metricOf(uint256 marketId) external view override returns (bytes32) {
        return _markets[marketId].metricId;
    }

    function creatorIdsOf(uint256 marketId) external view override returns (bytes32[] memory) {
        return _markets[marketId].creatorIds;
    }
}
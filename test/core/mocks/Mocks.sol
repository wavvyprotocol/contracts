// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IRiskManager } from "../../../contracts/interfaces/IRiskManager.sol";

/// @notice Configurable ERC20 for vault decimal tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRiskManager is IRiskManager {
    struct Config {
        bool paused;
        uint256 maxLeverage;
        uint256 minMargin;
        uint256 openInterestCap;
        uint256 maintenanceMarginBps;
        uint256 liquidationPenaltyBps;
        uint256 liquidatorShareBps;
        uint256 tradingFeeBps;
        uint256 markDeviationPauseBps;
        uint256 fundingCoefficient;
        uint256 maxFundingRatePerBlock;
        uint256 creatorShareBps;
        uint256 copyFeeBps;
        uint256 curatorShareBps;
    }

    mapping(uint256 => Config) private _configs;

    function setConfig(uint256 marketId, Config calldata config) external {
        _configs[marketId] = config;
    }

    function setPaused(uint256 marketId, bool paused) external {
        _configs[marketId].paused = paused;
    }

    function setMaintenanceMarginBps(uint256 marketId, uint256 bps) external {
        _configs[marketId].maintenanceMarginBps = bps;
    }

    function setTradingFeeBps(uint256 marketId, uint256 bps) external {
        _configs[marketId].tradingFeeBps = bps;
    }

    function setOpenInterestCap(uint256 marketId, uint256 cap) external {
        _configs[marketId].openInterestCap = cap;
    }

    function isMarketPaused(uint256 marketId) external view override returns (bool) {
        return _configs[marketId].paused;
    }

    function maxLeverage(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].maxLeverage;
    }

    function minMargin(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].minMargin;
    }

    function openInterestCap(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].openInterestCap;
    }

    function maintenanceMarginBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].maintenanceMarginBps;
    }

    function liquidationPenaltyBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].liquidationPenaltyBps;
    }

    function liquidatorShareBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].liquidatorShareBps;
    }

    function tradingFeeBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].tradingFeeBps;
    }

    function markDeviationPauseBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].markDeviationPauseBps;
    }

    function fundingCoefficient(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].fundingCoefficient;
    }

    function maxFundingRatePerBlock(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].maxFundingRatePerBlock;
    }

    function creatorShareBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].creatorShareBps;
    }

    function copyFeeBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].copyFeeBps;
    }

    function curatorShareBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].curatorShareBps;
    }
}
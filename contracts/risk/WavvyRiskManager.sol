// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IRiskManager } from "../interfaces/IRiskManager.sol";
import { BPS_DENOMINATOR, WAD } from "../utils/Constants.sol";

/// @notice Single source of risk truth for the whole system. The house and the vAMM read every limit from here on each state-changing call instead of carrying their own copies, so one change moves the whole system.
///
/// Parameters live at two levels: type defaults (single-name, index) that seed a market, and per-market values that can be tuned after seeding. Markets must be configured before they can trade, unconfigured getters revert.
///
/// Every parameter setter requires the admin role, which the timelock holds after handover. Pausing is the one emergency action a PAUSER_ROLE can take alone, unpausing and resetting the circuit breaker go back through the timelock.
contract WavvyRiskManager is AccessControl, IRiskManager {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint8 public constant TYPE_SINGLE_NAME = 0;
    uint8 public constant TYPE_INDEX = 1;

    struct RiskParams {
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

    mapping(uint8 => RiskParams) private _typeDefaults;
    mapping(uint8 => bool) private _typeDefaultsSet;

    mapping(uint256 => RiskParams) private _marketParams;
    mapping(uint256 => uint8) private _marketType;
    mapping(uint256 => bool) private _configured;
    mapping(uint256 => bool) private _paused;
    mapping(uint256 => bool) private _breakerTripped;

    error MarketNotConfigured(uint256 marketId);
    error MarketAlreadyConfigured(uint256 marketId);
    error TypeDefaultsMissing(uint8 marketType);
    error InvalidMarketType(uint8 marketType);
    error InvalidParams();

    event TypeDefaultsSet(uint8 indexed marketType);
    event MarketConfigured(uint256 indexed marketId, uint8 marketType);
    event MarketParamsUpdated(uint256 indexed marketId);
    event MarketPaused(uint256 indexed marketId);
    event MarketUnpaused(uint256 indexed marketId);
    event CircuitBreakerTripped(uint256 indexed marketId);
    event CircuitBreakerReset(uint256 indexed marketId);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Set the default parameters for a market type. New markets seed from these. Funding parameters are never defaulted by the contract: they must be supplied, derived from the approved annualized target.
    function setTypeDefaults(uint8 marketType, RiskParams calldata params) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (marketType > TYPE_INDEX) revert InvalidMarketType(marketType);
        _validate(params);
        _typeDefaults[marketType] = params;
        _typeDefaultsSet[marketType] = true;
        emit TypeDefaultsSet(marketType);
    }

    /// @notice Seed a market from its type defaults. Must run before the market can trade.
    function configureMarket(uint256 marketId, uint8 marketType) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (marketType > TYPE_INDEX) revert InvalidMarketType(marketType);
        if (_configured[marketId]) revert MarketAlreadyConfigured(marketId);
        if (!_typeDefaultsSet[marketType]) revert TypeDefaultsMissing(marketType);
        _marketParams[marketId] = _typeDefaults[marketType];
        _marketType[marketId] = marketType;
        _configured[marketId] = true;
        emit MarketConfigured(marketId, marketType);
    }

    /// @notice Replace every parameter of a configured market.
    function setMarketParams(uint256 marketId, RiskParams calldata params) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireConfigured(marketId);
        _validate(params);
        _marketParams[marketId] = params;
        emit MarketParamsUpdated(marketId);
    }

    function setMaxLeverage(uint256 marketId, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RiskParams memory p = _params(marketId);
        p.maxLeverage = value;
        _store(marketId, p);
    }

    function setMinMargin(uint256 marketId, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RiskParams memory p = _params(marketId);
        p.minMargin = value;
        _store(marketId, p);
    }

    function setOpenInterestCap(uint256 marketId, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RiskParams memory p = _params(marketId);
        p.openInterestCap = value;
        _store(marketId, p);
    }

    function setMaintenanceMarginBps(uint256 marketId, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RiskParams memory p = _params(marketId);
        p.maintenanceMarginBps = value;
        _store(marketId, p);
    }

    function setLiquidationParams(uint256 marketId, uint256 penaltyBps, uint256 lootShareBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        RiskParams memory p = _params(marketId);
        p.liquidationPenaltyBps = penaltyBps;
        p.liquidatorShareBps = lootShareBps;
        _store(marketId, p);
    }

    function setTradingFeeBps(uint256 marketId, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RiskParams memory p = _params(marketId);
        p.tradingFeeBps = value;
        _store(marketId, p);
    }

    function setMarkDeviationPauseBps(uint256 marketId, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RiskParams memory p = _params(marketId);
        p.markDeviationPauseBps = value;
        _store(marketId, p);
    }

    function setFundingParams(uint256 marketId, uint256 coefficient, uint256 maxRatePerBlock)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        RiskParams memory p = _params(marketId);
        p.fundingCoefficient = coefficient;
        p.maxFundingRatePerBlock = maxRatePerBlock;
        _store(marketId, p);
    }

    function setFeeShares(uint256 marketId, uint256 creatorBps, uint256 copyBps, uint256 curatorBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        RiskParams memory p = _params(marketId);
        p.creatorShareBps = creatorBps;
        p.copyFeeBps = copyBps;
        p.curatorShareBps = curatorBps;
        _store(marketId, p);
    }

    /// @notice Pause a market. Emergency action available to the pauser role, opens are blocked while closes stay available.
    function pauseMarket(uint256 marketId) external onlyRole(PAUSER_ROLE) {
        _requireConfigured(marketId);
        if (!_paused[marketId]) {
            _paused[marketId] = true;
            emit MarketPaused(marketId);
        }
    }

    /// @notice Unpause a market. Admin only, so reopening goes through the timelock.
    function unpauseMarket(uint256 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireConfigured(marketId);
        if (_paused[marketId]) {
            _paused[marketId] = false;
            emit MarketUnpaused(marketId);
        }
    }

    /// @notice Trip a market's circuit breaker. Opens are blocked like a pause, but the state reads separately so the reason is visible. Keeper or operator action after an extreme move, reset is admin only.
    function tripCircuitBreaker(uint256 marketId) external onlyRole(PAUSER_ROLE) {
        _requireConfigured(marketId);
        if (!_breakerTripped[marketId]) {
            _breakerTripped[marketId] = true;
            emit CircuitBreakerTripped(marketId);
        }
    }

    function resetCircuitBreaker(uint256 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireConfigured(marketId);
        if (_breakerTripped[marketId]) {
            _breakerTripped[marketId] = false;
            emit CircuitBreakerReset(marketId);
        }
    }

    function isMarketPaused(uint256 marketId) external view override returns (bool) {
        return _paused[marketId];
    }

    function circuitBreakerTripped(uint256 marketId) external view override returns (bool) {
        return _breakerTripped[marketId];
    }

    function marketTypeOf(uint256 marketId) external view returns (uint8) {
        return _marketType[marketId];
    }

    function marketConfigured(uint256 marketId) external view returns (bool) {
        return _configured[marketId];
    }

    function maxLeverage(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).maxLeverage;
    }

    function minMargin(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).minMargin;
    }

    function openInterestCap(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).openInterestCap;
    }

    function maintenanceMarginBps(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).maintenanceMarginBps;
    }

    function liquidationPenaltyBps(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).liquidationPenaltyBps;
    }

    function liquidatorShareBps(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).liquidatorShareBps;
    }

    function tradingFeeBps(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).tradingFeeBps;
    }

    function markDeviationPauseBps(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).markDeviationPauseBps;
    }

    function fundingCoefficient(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).fundingCoefficient;
    }

    function maxFundingRatePerBlock(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).maxFundingRatePerBlock;
    }

    function creatorShareBps(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).creatorShareBps;
    }

    function copyFeeBps(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).copyFeeBps;
    }

    function curatorShareBps(uint256 marketId) external view override returns (uint256) {
        return _params(marketId).curatorShareBps;
    }

    function paramsOf(uint256 marketId) external view returns (RiskParams memory) {
        return _params(marketId);
    }

    function typeDefaultsOf(uint8 marketType) external view returns (RiskParams memory) {
        if (!_typeDefaultsSet[marketType]) revert TypeDefaultsMissing(marketType);
        return _typeDefaults[marketType];
    }

    function _params(uint256 marketId) internal view returns (RiskParams memory) {
        _requireConfigured(marketId);
        return _marketParams[marketId];
    }

    function _requireConfigured(uint256 marketId) internal view {
        if (!_configured[marketId]) revert MarketNotConfigured(marketId);
    }

    function _store(uint256 marketId, RiskParams memory params) internal {
        _validate(params);
        _marketParams[marketId] = params;
        emit MarketParamsUpdated(marketId);
    }

    function _validate(RiskParams memory p) internal pure {
        if (
            p.maxLeverage < WAD || p.minMargin == 0 || p.openInterestCap == 0 || p.maintenanceMarginBps == 0
                || p.maintenanceMarginBps >= BPS_DENOMINATOR || p.liquidationPenaltyBps > BPS_DENOMINATOR
                || p.liquidatorShareBps > BPS_DENOMINATOR || p.tradingFeeBps > BPS_DENOMINATOR
                || p.markDeviationPauseBps == 0 || p.markDeviationPauseBps > BPS_DENOMINATOR
                || p.fundingCoefficient == 0 || p.maxFundingRatePerBlock == 0
                || p.creatorShareBps > BPS_DENOMINATOR || p.copyFeeBps > BPS_DENOMINATOR
                || p.curatorShareBps > BPS_DENOMINATOR
        ) {
            revert InvalidParams();
        }
    }
}
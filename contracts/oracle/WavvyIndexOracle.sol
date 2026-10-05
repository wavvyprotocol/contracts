// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IWavvyIndexOracle } from "../interfaces/IWavvyIndexOracle.sol";
import { IWavvyOracle } from "../interfaces/IWavvyOracle.sol";
import { WavvyMath } from "../lib/WavvyMath.sol";
import { INDEX_BASE, INDEX_FLOOR, WAD } from "../utils/Constants.sol";

/// @notice Index oracle. The index value is computed onchain from constituent
/// metric TWAPs, so index markets spend no oracle execution budget.
///
/// value = 1000 * (1 + average(current TWAP / baseline - 1))
///
/// Constituents with a frozen flag or stale data are excluded from the
/// average. A constituent without enough observation history is excluded too.
/// When no constituent is usable the value is invalid and must not be traded
/// against. The result is floored at INDEX_FLOOR to keep index and vAMM math
/// stable in the extreme downside case.
contract WavvyIndexOracle is AccessControl, IWavvyIndexOracle {
    struct Constituent {
        bytes32 metricId;
        uint256 baseline;
        bool frozen;
    }

    struct IndexMarket {
        Constituent[] constituents;
        bool registered;
    }

    IWavvyOracle public immutable oracle;

    mapping(uint256 => IndexMarket) private _markets;

    error UnknownIndexMarket();
    error ConstituentOutOfRange();
    error DuplicateMetric();
    error LengthMismatch();
    error ZeroBaseline();
    error EmptyConstituents();
    error DuplicateIndexMarket();

    event IndexMarketRegistered(uint256 indexed marketId, uint256 constituentCount);
    event IndexRebalanced(uint256 indexed marketId, uint256 constituentCount);
    event ConstituentFrozenSet(uint256 indexed marketId, uint256 indexed index, bool frozen);

    constructor(IWavvyOracle oracle_, address admin) {
        oracle = oracle_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Define the constituents and baselines of an index market.
    /// Baselines are the metric values at index inception.
    function registerIndexMarket(uint256 marketId, bytes32[] calldata metricIds, uint256[] calldata baselines)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IndexMarket storage market = _markets[marketId];
        if (market.registered) revert DuplicateIndexMarket();
        _setConstituents(market, metricIds, baselines);
        market.registered = true;
        emit IndexMarketRegistered(marketId, metricIds.length);
    }

    /// @notice Replace the constituent list and set fresh baselines. A new
    /// constituent starts at zero growth. Rebalancing is an operator action;
    /// no schedule is hardcoded in the contract.
    function rebalance(uint256 marketId, bytes32[] calldata metricIds, uint256[] calldata baselines)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IndexMarket storage market = _markets[marketId];
        if (!market.registered) revert UnknownIndexMarket();
        _setConstituents(market, metricIds, baselines);
        emit IndexRebalanced(marketId, metricIds.length);
    }

    /// @notice Freeze or unfreeze one constituent. A frozen constituent keeps
    /// its last valid contribution out of the average until it is unfrozen.
    function setConstituentFrozen(uint256 marketId, uint256 index, bool frozen)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IndexMarket storage market = _markets[marketId];
        if (!market.registered) revert UnknownIndexMarket();
        if (index >= market.constituents.length) revert ConstituentOutOfRange();
        market.constituents[index].frozen = frozen;
        emit ConstituentFrozenSet(marketId, index, frozen);
    }

    function indexValue(uint256 marketId) external view override returns (uint256 value, bool valid) {
        IndexMarket storage market = _markets[marketId];
        if (!market.registered) return (0, false);

        int256 growthSum;
        uint256 active;

        uint256 len = market.constituents.length;
        for (uint256 i; i < len; ++i) {
            Constituent storage c = market.constituents[i];
            if (c.frozen) continue;
            if (!oracle.isFresh(c.metricId)) continue;
            try oracle.getTWAP(c.metricId) returns (uint256 twap) {
                // TWAP of a fresh metric cannot be zero, but a zero is never
                // treated as a value: skip instead of counting it as growth.
                if (twap == 0) continue;
                int256 growth = WavvyMath.subSigned(WavvyMath.signed(WavvyMath.divWad(twap, c.baseline)), WavvyMath.signed(WAD));
                growthSum = WavvyMath.addSigned(growthSum, growth);
                active++;
            } catch {
                continue;
            }
        }

        if (active == 0) return (0, false);

        int256 average = WavvyMath.divSignedByCount(growthSum, active);
        int256 raw = WavvyMath.addSigned(WavvyMath.signed(INDEX_BASE), WavvyMath.mulSigned(WavvyMath.signed(INDEX_BASE), average));

        if (raw <= 0) return (INDEX_FLOOR, true);
        value = uint256(raw);
        if (value < INDEX_FLOOR) {
            value = INDEX_FLOOR;
        }
        valid = true;
    }

    function constituentCount(uint256 marketId) external view override returns (uint256) {
        return _markets[marketId].constituents.length;
    }

    function constituent(uint256 marketId, uint256 index)
        external
        view
        override
        returns (bytes32 metricId, uint256 baseline, bool frozen)
    {
        Constituent storage c = _markets[marketId].constituents[index];
        return (c.metricId, c.baseline, c.frozen);
    }

    function _setConstituents(IndexMarket storage market, bytes32[] calldata metricIds, uint256[] calldata baselines)
        internal
    {
        uint256 len = metricIds.length;
        if (len == 0) revert EmptyConstituents();
        if (len != baselines.length) revert LengthMismatch();
        delete market.constituents;
        for (uint256 i; i < len; ++i) {
            if (baselines[i] == 0) revert ZeroBaseline();
            for (uint256 j; j < i; ++j) {
                if (metricIds[j] == metricIds[i]) revert DuplicateMetric();
            }
            market.constituents.push(Constituent({ metricId: metricIds[i], baseline: baselines[i], frozen: false }));
        }
    }
}
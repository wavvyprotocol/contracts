// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IWavvyIndexOracle } from "../interfaces/IWavvyIndexOracle.sol";
import { IWavvyOracle } from "../interfaces/IWavvyOracle.sol";

/// @notice Settable metric oracle for local tests and demos. Values and freshness are pushed in from the test or script.
contract MockOracle is IWavvyOracle {
    mapping(bytes32 => uint256) private _twaps;
    mapping(bytes32 => bool) private _fresh;

    error Stale();

    function set(bytes32 metricId, uint256 twap, bool fresh) external {
        _twaps[metricId] = twap;
        _fresh[metricId] = fresh;
    }

    function getTWAP(bytes32 metricId) external view override returns (uint256) {
        if (!_fresh[metricId]) revert Stale();
        return _twaps[metricId];
    }

    function getTWAP(bytes32 metricId, uint64) external view override returns (uint256) {
        if (!_fresh[metricId]) revert Stale();
        return _twaps[metricId];
    }

    function latestValue(bytes32 metricId) external view override returns (uint256) {
        return _twaps[metricId];
    }

    function lastUpdateAt(bytes32) external pure override returns (uint64) {
        return 0;
    }

    function isFresh(bytes32 metricId) external view override returns (bool) {
        return _fresh[metricId];
    }

    function isSuspended(bytes32) external pure override returns (bool) {
        return false;
    }

    function isFrozen(bytes32) external pure override returns (bool) {
        return false;
    }
}

/// @notice Settable index oracle for local tests and demos.
contract MockIndexOracle is IWavvyIndexOracle {
    mapping(uint256 => uint256) private _values;
    mapping(uint256 => bool) private _valid;

    function set(uint256 marketId, uint256 value, bool valid) external {
        _values[marketId] = value;
        _valid[marketId] = valid;
    }

    function indexValue(uint256 marketId) external view override returns (uint256 value, bool valid) {
        return (_values[marketId], _valid[marketId]);
    }

    function constituentCount(uint256) external pure override returns (uint256) {
        return 0;
    }

    function constituent(uint256, uint256) external pure override returns (bytes32, uint256, bool) {
        return (bytes32(0), 0, false);
    }
}
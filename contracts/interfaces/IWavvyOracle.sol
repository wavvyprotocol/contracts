// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Metric oracle surface consumed by trading contracts. Values and
/// TWAPs are 18-decimal fixed point.
interface IWavvyOracle {
    /// @notice Time-weighted average over the metric's configured window.
    function getTWAP(bytes32 metricId) external view returns (uint256);

    /// @notice Time-weighted average over an explicit window, clamped to the
    /// available observation history.
    function getTWAP(bytes32 metricId, uint64 window) external view returns (uint256);

    /// @notice Most recent accepted value.
    function latestValue(bytes32 metricId) external view returns (uint256);

    /// @notice Timestamp of the most recent accepted value.
    function lastUpdateAt(bytes32 metricId) external view returns (uint64);

    /// @notice True when the metric has data, is not suspended or frozen, and
    /// the last update is within the heartbeat.
    function isFresh(bytes32 metricId) external view returns (bool);

    function isSuspended(bytes32 metricId) external view returns (bool);

    function isFrozen(bytes32 metricId) external view returns (bool);
}
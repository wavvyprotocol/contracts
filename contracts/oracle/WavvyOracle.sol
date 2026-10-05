// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IReceiver } from "../interfaces/IReceiver.sol";
import { IWavvyOracle } from "../interfaces/IWavvyOracle.sol";
import { TWAPLib } from "../lib/TWAPLib.sol";
import { WavvyMath } from "../lib/WavvyMath.sol";
import { BPS_DENOMINATOR, MAX_OBSERVATIONS } from "../utils/Constants.sol";

/// @notice Metric oracle. Receives reports from the CRE receiver entrypoint
/// and from the fallback keeper, keeps per-metric TWAP observations, and
/// exposes freshness so trading contracts can pause on stale data.
///
/// Report payload delivered to `onReport`:
/// abi.encode(bytes32 metricId, uint256 value, uint64 observedAt, uint8 status).
/// Status codes: 0 OK, 1 SUSPENDED, 2 NOT_FOUND, 3 STALE, 4 INVALID.
/// A missing metric is never posted as zero: zero values revert and SUSPENDED
/// or NOT_FOUND reports freeze the metric without changing its value.
contract WavvyOracle is AccessControl, IWavvyOracle, IReceiver {
    bytes32 public constant CRE_REPORTER_ROLE = keccak256("CRE_REPORTER_ROLE");
    bytes32 public constant FALLBACK_KEEPER_ROLE = keccak256("FALLBACK_KEEPER_ROLE");

    uint8 public constant STATUS_OK = 0;
    uint8 public constant STATUS_SUSPENDED = 1;
    uint8 public constant STATUS_NOT_FOUND = 2;
    uint8 public constant STATUS_STALE = 3;
    uint8 public constant STATUS_INVALID = 4;

    struct Metric {
        TWAPLib.State observations;
        uint64 lastUpdateAt;
        uint64 heartbeat;
        uint64 twapWindow;
        uint64 minTwapWindow;
        uint16 maxDeviationBps;
        uint16 circuitBreakerBps;
        uint256 lastValue;
        bool registered;
        bool suspended;
        bool adminSuspended;
        bool frozen;
    }

    mapping(bytes32 => Metric) private _metrics;

    /// @notice Forwarder address allowed to deliver reports. Zero accepts any
    /// holder of the reporter role.
    address public creForwarder;
    bytes32 public expectedWorkflowId;
    bytes10 public expectedWorkflowName;
    address public expectedWorkflowOwner;

    error UnauthorizedReporter();
    error UnauthorizedForwarder();
    error WorkflowNotAllowed();
    error InvalidMetadata();
    error UnknownMetric();
    error ZeroMetric();
    error StaleOracle();
    error FutureTimestamp();
    error DeviationTooHigh();
    error CircuitBreakerActive();
    error CreHealthy();
    error InvalidReport();
    error InvalidConfig();
    error DuplicateMetric();

    event MetricRegistered(
        bytes32 indexed metricId,
        uint64 heartbeat,
        uint64 twapWindow,
        uint64 minTwapWindow,
        uint16 maxDeviationBps,
        uint16 circuitBreakerBps
    );
    event MetricConfigUpdated(
        bytes32 indexed metricId,
        uint64 heartbeat,
        uint64 twapWindow,
        uint64 minTwapWindow,
        uint16 maxDeviationBps,
        uint16 circuitBreakerBps
    );
    event MetricUpdated(
        bytes32 indexed metricId, uint256 value, uint64 observedAt, uint8 status, address indexed reporter
    );
    event ForwarderUpdated(address indexed forwarder);
    event WorkflowRuleUpdated(bytes32 workflowId, bytes10 workflowName, address workflowOwner);
    event MetricRebased(bytes32 indexed metricId, uint256 value, uint64 observedAt);
    event MetricSuspended(bytes32 indexed metricId, uint8 status);
    event MetricResumed(bytes32 indexed metricId);
    event CircuitBroken(bytes32 indexed metricId, uint256 value, uint256 lastValue);
    event CircuitReset(bytes32 indexed metricId);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Register a metric with its freshness and guard configuration.
    /// TWAP windows come from risk review; nothing here is chain-specific.
    function registerMetric(
        bytes32 metricId,
        uint64 heartbeat,
        uint64 twapWindow,
        uint64 minTwapWindow,
        uint16 maxDeviationBps,
        uint16 circuitBreakerBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Metric storage m = _metrics[metricId];
        if (m.registered) revert DuplicateMetric();
        _validateConfig(heartbeat, twapWindow, minTwapWindow, maxDeviationBps, circuitBreakerBps);
        m.registered = true;
        m.heartbeat = heartbeat;
        m.twapWindow = twapWindow;
        m.minTwapWindow = minTwapWindow;
        m.maxDeviationBps = maxDeviationBps;
        m.circuitBreakerBps = circuitBreakerBps;
        emit MetricRegistered(metricId, heartbeat, twapWindow, minTwapWindow, maxDeviationBps, circuitBreakerBps);
    }

    function setMetricConfig(
        bytes32 metricId,
        uint64 heartbeat,
        uint64 twapWindow,
        uint64 minTwapWindow,
        uint16 maxDeviationBps,
        uint16 circuitBreakerBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Metric storage m = _metrics[metricId];
        if (!m.registered) revert UnknownMetric();
        _validateConfig(heartbeat, twapWindow, minTwapWindow, maxDeviationBps, circuitBreakerBps);
        m.heartbeat = heartbeat;
        m.twapWindow = twapWindow;
        m.minTwapWindow = minTwapWindow;
        m.maxDeviationBps = maxDeviationBps;
        m.circuitBreakerBps = circuitBreakerBps;
        emit MetricConfigUpdated(metricId, heartbeat, twapWindow, minTwapWindow, maxDeviationBps, circuitBreakerBps);
    }

    /// @notice Freeze or unfreeze a metric after the platform status changes.
    /// An admin suspension is sticky: only the admin can clear it, while
    /// reporter-driven suspensions clear on the next valid report.
    function setSuspended(bytes32 metricId, bool suspended) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Metric storage m = _metrics[metricId];
        if (!m.registered) revert UnknownMetric();
        if (m.adminSuspended == suspended) return;
        m.adminSuspended = suspended;
        if (suspended) {
            emit MetricSuspended(metricId, STATUS_SUSPENDED);
        } else {
            emit MetricResumed(metricId);
        }
    }

    /// @notice Clear the circuit breaker after inspection so updates flow
    /// again. Use `rebaseMetric` instead when the move was legitimate and the
    /// deviation reference must move with it.
    function resetCircuitBreaker(bytes32 metricId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Metric storage m = _metrics[metricId];
        if (!m.registered) revert UnknownMetric();
        m.frozen = false;
        emit CircuitReset(metricId);
    }

    /// @notice Accept an inspected value after a legitimate jump, rebasing the
    /// deviation reference and clearing the circuit breaker so reporting
    /// resumes. The value is recorded as a normal observation.
    function rebaseMetric(bytes32 metricId, uint256 value, uint64 observedAt) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Metric storage m = _metrics[metricId];
        if (!m.registered) revert UnknownMetric();
        if (value == 0) revert ZeroMetric();
        if (observedAt > block.timestamp) revert FutureTimestamp();
        if (observedAt <= m.lastUpdateAt) revert StaleOracle();
        TWAPLib.write(m.observations, value, observedAt, MAX_OBSERVATIONS);
        m.lastValue = value;
        m.lastUpdateAt = observedAt;
        m.frozen = false;
        emit MetricRebased(metricId, value, observedAt);
        emit CircuitReset(metricId);
    }

    /// @notice Pin the CRE forwarder, the only address that may deliver
    /// reports once set. Zero accepts any reporter-role holder.
    function setCreForwarder(address forwarder) external onlyRole(DEFAULT_ADMIN_ROLE) {
        creForwarder = forwarder;
        emit ForwarderUpdated(forwarder);
    }

    /// @notice Restrict reports to one workflow. A zero field skips that
    /// check, so an unconfigured deployment accepts any reporter.
    function setWorkflowRule(bytes32 workflowId, bytes10 workflowName, address workflowOwner)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        expectedWorkflowId = workflowId;
        expectedWorkflowName = workflowName;
        expectedWorkflowOwner = workflowOwner;
        emit WorkflowRuleUpdated(workflowId, workflowName, workflowOwner);
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice CRE receiver entrypoint. Only the CRE reporter role, and the
    /// pinned forwarder once configured, may deliver reports. Metadata must
    /// match the configured workflow rule when one is set.
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (!hasRole(CRE_REPORTER_ROLE, msg.sender)) revert UnauthorizedReporter();
        if (creForwarder != address(0) && msg.sender != creForwarder) revert UnauthorizedForwarder();
        _validateWorkflow(metadata);
        (bytes32 metricId, uint256 value, uint64 observedAt, uint8 status) =
            abi.decode(report, (bytes32, uint256, uint64, uint8));
        _post(metricId, value, observedAt, status, false);
    }

    /// @dev CRE metadata is packed as workflowId, workflowName, workflowOwner.
    function _validateWorkflow(bytes calldata metadata) internal view {
        if (expectedWorkflowId == bytes32(0) && expectedWorkflowName == bytes10(0) && expectedWorkflowOwner == address(0)) {
            return;
        }
        if (metadata.length < 62) revert InvalidMetadata();
        bytes32 workflowId = bytes32(metadata[0:32]);
        bytes10 workflowName = bytes10(metadata[32:42]);
        address workflowOwner = address(bytes20(metadata[42:62]));
        if (expectedWorkflowId != bytes32(0) && workflowId != expectedWorkflowId) revert WorkflowNotAllowed();
        if (expectedWorkflowName != bytes10(0) && workflowName != expectedWorkflowName) revert WorkflowNotAllowed();
        if (expectedWorkflowOwner != address(0) && workflowOwner != expectedWorkflowOwner) revert WorkflowNotAllowed();
    }

    /// @notice Fallback keeper entrypoint. Allowed only while the metric is
    /// not fresh, so the fallback never writes over healthy CRE data.
    function postFallback(bytes32 metricId, uint256 value, uint64 observedAt) external {
        if (!hasRole(FALLBACK_KEEPER_ROLE, msg.sender)) revert UnauthorizedReporter();
        _post(metricId, value, observedAt, STATUS_OK, true);
    }

    function getTWAP(bytes32 metricId) external view override returns (uint256) {
        Metric storage m = _metrics[metricId];
        if (!m.registered) revert UnknownMetric();
        return TWAPLib.getTWAP(m.observations, m.twapWindow, m.minTwapWindow, uint64(block.timestamp));
    }

    function getTWAP(bytes32 metricId, uint64 window) external view override returns (uint256) {
        Metric storage m = _metrics[metricId];
        if (!m.registered) revert UnknownMetric();
        return TWAPLib.getTWAP(m.observations, window, m.minTwapWindow, uint64(block.timestamp));
    }

    function latestValue(bytes32 metricId) external view override returns (uint256) {
        return _metrics[metricId].lastValue;
    }

    function lastUpdateAt(bytes32 metricId) external view override returns (uint64) {
        return _metrics[metricId].lastUpdateAt;
    }

    function isFresh(bytes32 metricId) external view override returns (bool) {
        return _isFresh(_metrics[metricId]);
    }

    function isSuspended(bytes32 metricId) external view override returns (bool) {
        Metric storage m = _metrics[metricId];
        return m.suspended || m.adminSuspended;
    }

    function isFrozen(bytes32 metricId) external view override returns (bool) {
        return _metrics[metricId].frozen;
    }

    function metricConfig(bytes32 metricId)
        external
        view
        returns (uint64 heartbeat, uint64 twapWindow, uint64 minTwapWindow, uint16 maxDeviationBps, uint16 circuitBreakerBps, bool registered)
    {
        Metric storage m = _metrics[metricId];
        return (m.heartbeat, m.twapWindow, m.minTwapWindow, m.maxDeviationBps, m.circuitBreakerBps, m.registered);
    }

    function _post(bytes32 metricId, uint256 value, uint64 observedAt, uint8 status, bool fromFallback) internal {
        Metric storage m = _metrics[metricId];
        if (!m.registered) revert UnknownMetric();
        if (status == STATUS_INVALID) revert InvalidReport();
        if (observedAt > block.timestamp) revert FutureTimestamp();

        if (status == STATUS_STALE) {
            // A stale reading never updates the value or the heartbeat.
            emit MetricUpdated(metricId, m.lastValue, observedAt, status, msg.sender);
            return;
        }

        if (status == STATUS_SUSPENDED || status == STATUS_NOT_FOUND) {
            if (!m.suspended) {
                m.suspended = true;
                emit MetricSuspended(metricId, status);
            }
            emit MetricUpdated(metricId, m.lastValue, observedAt, status, msg.sender);
            return;
        }

        if (status != STATUS_OK) revert InvalidReport();
        if (value == 0) revert ZeroMetric();
        if (fromFallback && _isFresh(m)) revert CreHealthy();
        if (observedAt <= m.lastUpdateAt) revert StaleOracle();
        if (m.frozen) revert CircuitBreakerActive();

        if (m.lastValue > 0) {
            uint256 devBps = WavvyMath.deviationBps(value, m.lastValue);
            if (devBps > m.circuitBreakerBps) {
                // Extreme movement: reject the value, keep the previous data,
                // and freeze the metric until an operator inspects the source.
                m.frozen = true;
                emit CircuitBroken(metricId, value, m.lastValue);
                return;
            }
            if (devBps > m.maxDeviationBps) revert DeviationTooHigh();
        }

        TWAPLib.write(m.observations, value, observedAt, MAX_OBSERVATIONS);
        m.lastValue = value;
        m.lastUpdateAt = observedAt;
        if (m.suspended) {
            // Fresh valid data clears a reporter-driven suspension only. An
            // admin suspension stays until the admin clears it.
            m.suspended = false;
            emit MetricResumed(metricId);
        }
        emit MetricUpdated(metricId, value, observedAt, status, msg.sender);
    }

    function _isFresh(Metric storage m) internal view returns (bool) {
        if (!m.registered || m.frozen || m.suspended || m.adminSuspended) return false;
        if (m.lastUpdateAt == 0) return false;
        return block.timestamp - m.lastUpdateAt <= m.heartbeat;
    }

    function _validateConfig(
        uint64 heartbeat,
        uint64 twapWindow,
        uint64 minTwapWindow,
        uint16 maxDeviationBps,
        uint16 circuitBreakerBps
    ) internal pure {
        if (heartbeat == 0 || twapWindow == 0 || minTwapWindow == 0 || minTwapWindow > twapWindow) {
            revert InvalidConfig();
        }
        if (maxDeviationBps > circuitBreakerBps || circuitBreakerBps > BPS_DENOMINATOR) {
            revert InvalidConfig();
        }
    }
}
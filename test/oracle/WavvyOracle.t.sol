// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { WavvyOracle } from "../../contracts/oracle/WavvyOracle.sol";
import { TWAPLib } from "../../contracts/lib/TWAPLib.sol";

contract WavvyOracleTest is Test {
    WavvyOracle internal oracle;

    address internal admin = address(0xA11CE);
    address internal creReporter = address(0xC0FFEE);
    address internal fallbackKeeper = address(0xBEEF);
    address internal stranger = address(0xDEAD);

    bytes32 internal constant METRIC = keccak256("youtube:channel-1:subscribers");

    uint64 internal constant HEARTBEAT = 3600;
    uint64 internal constant TWAP_WINDOW = 7200;
    uint64 internal constant MIN_WINDOW = 1800;
    uint16 internal constant MAX_DEVIATION_BPS = 500;
    uint16 internal constant CIRCUIT_BREAKER_BPS = 2000;

    uint64 internal constant START_TIME = 1_000_000;

    // Read once: any external call between expectRevert and the target call
    // would consume the revert expectation.
    uint8 internal okStatus;
    uint8 internal suspendedStatus;
    uint8 internal staleStatus;

    function setUp() public {
        vm.warp(START_TIME);
        oracle = new WavvyOracle(admin);
        vm.startPrank(admin);
        oracle.registerMetric(METRIC, HEARTBEAT, TWAP_WINDOW, MIN_WINDOW, MAX_DEVIATION_BPS, CIRCUIT_BREAKER_BPS);
        oracle.grantRole(oracle.CRE_REPORTER_ROLE(), creReporter);
        oracle.grantRole(oracle.FALLBACK_KEEPER_ROLE(), fallbackKeeper);
        vm.stopPrank();

        okStatus = oracle.STATUS_OK();
        suspendedStatus = oracle.STATUS_SUSPENDED();
        staleStatus = oracle.STATUS_STALE();
    }

    function _creReport(uint256 value, uint64 observedAt) internal {
        _creReportStatus(value, observedAt, okStatus);
    }

    function _creReportStatus(uint256 value, uint64 observedAt, uint8 status) internal {
        vm.prank(creReporter);
        oracle.onReport("", abi.encode(METRIC, value, observedAt, status));
    }

    function _expectCreRevert(uint256 value, uint64 observedAt, bytes4 selector) internal {
        vm.prank(creReporter);
        vm.expectRevert(selector);
        oracle.onReport("", abi.encode(METRIC, value, observedAt, okStatus));
    }

    function test_CreReportUpdatesValueAndTwap() public {
        _creReport(1000e18, START_TIME);

        assertEq(oracle.latestValue(METRIC), 1000e18);
        assertEq(oracle.lastUpdateAt(METRIC), START_TIME);
        assertTrue(oracle.isFresh(METRIC));

        // 30 minutes in: history reaches the minimum window.
        vm.warp(START_TIME + 1800);
        assertEq(oracle.getTWAP(METRIC), 1000e18);

        // One hour in: a second value inside the deviation guard.
        vm.warp(START_TIME + 3600);
        _creReport(1040e18, START_TIME + 3600);

        // Window clamps to the available history and averages both values.
        vm.warp(START_TIME + 7200);
        assertEq(oracle.getTWAP(METRIC), 1020e18);

        // Explicit window: the last hour is half 1000 and half 1040.
        vm.warp(START_TIME + 5400);
        assertEq(oracle.getTWAP(METRIC, 3600), 1020e18);
    }

    function test_TwapRevertsBeforeMinimumHistory() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + MIN_WINDOW - 1);
        vm.expectRevert(TWAPLib.InsufficientHistory.selector);
        oracle.getTWAP(METRIC);
    }

    function test_StaleReportReverts() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + 60);
        _expectCreRevert(1000e18, START_TIME, WavvyOracle.StaleOracle.selector);
    }

    function test_FutureTimestampReverts() public {
        _expectCreRevert(1000e18, START_TIME + 1, WavvyOracle.FutureTimestamp.selector);
    }

    function test_ZeroValueReverts() public {
        _expectCreRevert(0, START_TIME, WavvyOracle.ZeroMetric.selector);
    }

    function test_UnauthorizedReporterReverts() public {
        vm.startPrank(stranger);
        vm.expectRevert(WavvyOracle.UnauthorizedReporter.selector);
        oracle.onReport("", abi.encode(METRIC, 1000e18, START_TIME, okStatus));
        vm.expectRevert(WavvyOracle.UnauthorizedReporter.selector);
        oracle.postFallback(METRIC, 1000e18, START_TIME);
        vm.stopPrank();
    }

    function test_UnknownMetricReverts() public {
        vm.prank(creReporter);
        vm.expectRevert(WavvyOracle.UnknownMetric.selector);
        oracle.onReport("", abi.encode(keccak256("unknown"), 1000e18, START_TIME, okStatus));
    }

    function test_DeviationGuardHoldsSuspiciousUpdate() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + 60);
        _expectCreRevert(1080e18, START_TIME + 60, WavvyOracle.DeviationTooHigh.selector);
        assertEq(oracle.latestValue(METRIC), 1000e18);
    }

    function test_CircuitBreakerFreezesMetric() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + 60);

        // Extreme movement freezes the metric and rejects the value.
        _creReport(1500e18, START_TIME + 60);
        assertTrue(oracle.isFrozen(METRIC));
        assertFalse(oracle.isFresh(METRIC));
        assertEq(oracle.latestValue(METRIC), 1000e18);

        vm.warp(START_TIME + 120);
        _expectCreRevert(1000e18, START_TIME + 120, WavvyOracle.CircuitBreakerActive.selector);

        vm.prank(admin);
        oracle.resetCircuitBreaker(METRIC);
        vm.warp(START_TIME + 180);
        _creReport(1000e18, START_TIME + 180);
        assertTrue(oracle.isFresh(METRIC));
    }

    function test_SuspendedReportFreezesWithoutChangingValue() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + 60);
        _creReportStatus(0, START_TIME + 60, suspendedStatus);

        assertTrue(oracle.isSuspended(METRIC));
        assertFalse(oracle.isFresh(METRIC));
        assertEq(oracle.latestValue(METRIC), 1000e18);

        // Fresh valid data resumes the metric.
        vm.warp(START_TIME + 120);
        _creReport(1000e18, START_TIME + 120);
        assertFalse(oracle.isSuspended(METRIC));
        assertTrue(oracle.isFresh(METRIC));
    }

    function test_StaleStatusDoesNotUpdateValueOrHeartbeat() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + 60);
        _creReportStatus(0, START_TIME + 60, staleStatus);
        assertEq(oracle.latestValue(METRIC), 1000e18);
        assertEq(oracle.lastUpdateAt(METRIC), START_TIME);
    }

    function test_FreshnessWindowExpires() public {
        _creReport(1000e18, START_TIME);
        assertTrue(oracle.isFresh(METRIC));
        vm.warp(START_TIME + HEARTBEAT + 1);
        assertFalse(oracle.isFresh(METRIC));
    }

    function test_FallbackRejectedWhileCreIsHealthy() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + 60);
        vm.prank(fallbackKeeper);
        vm.expectRevert(WavvyOracle.CreHealthy.selector);
        oracle.postFallback(METRIC, 1040e18, START_TIME + 60);
    }

    function test_FallbackPostsWhenMetricIsStale() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + HEARTBEAT + 60);
        assertFalse(oracle.isFresh(METRIC));

        vm.prank(fallbackKeeper);
        oracle.postFallback(METRIC, 1040e18, uint64(block.timestamp));

        assertEq(oracle.latestValue(METRIC), 1040e18);
        assertTrue(oracle.isFresh(METRIC));
    }

    function test_FallbackRejectsZero() public {
        _creReport(1000e18, START_TIME);
        vm.warp(START_TIME + HEARTBEAT + 60);
        vm.prank(fallbackKeeper);
        vm.expectRevert(WavvyOracle.ZeroMetric.selector);
        oracle.postFallback(METRIC, 0, uint64(block.timestamp));
    }

    function test_RegisterGuards() public {
        vm.startPrank(admin);
        vm.expectRevert(WavvyOracle.DuplicateMetric.selector);
        oracle.registerMetric(METRIC, HEARTBEAT, TWAP_WINDOW, MIN_WINDOW, MAX_DEVIATION_BPS, CIRCUIT_BREAKER_BPS);

        vm.expectRevert(WavvyOracle.InvalidConfig.selector);
        oracle.registerMetric(keccak256("bad"), HEARTBEAT, TWAP_WINDOW, MIN_WINDOW, 2000, 500);
        vm.stopPrank();
    }
}
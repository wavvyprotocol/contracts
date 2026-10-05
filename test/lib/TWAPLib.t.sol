// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { TWAPLib } from "../../contracts/lib/TWAPLib.sol";

contract TWAPHarness {
    using TWAPLib for TWAPLib.State;

    TWAPLib.State internal state;

    function write(uint256 value, uint64 timestamp, uint16 capacity) external {
        state.write(value, timestamp, capacity);
    }

    function twap(uint64 window, uint64 minWindow, uint64 nowTs) external view returns (uint256) {
        return state.getTWAP(window, minWindow, nowTs);
    }

    function cumulativeAt(uint64 target) external view returns (uint256) {
        return state.cumulativeAt(target);
    }

}

/// @notice Hand-computed known answers for the observation ring buffer and
/// TWAP computation. Values are value-seconds averages worked out on paper.
contract TWAPLibTest is Test {
    TWAPHarness internal harness;

    function setUp() public {
        harness = new TWAPHarness();
    }

    function test_FirstWriteStartsSeries() public {
        harness.write(100e18, 1000, 16);

        // History exactly matches the minimum window.
        assertEq(harness.twap(100, 100, 1100), 100e18);
        assertEq(harness.cumulativeAt(1000), 0);
    }

    function test_SingleValueAveragesOverAvailableSpan() public {
        harness.write(100e18, 1000, 16);

        // 100 value-seconds per second from 1000 to 1100.
        assertEq(harness.twap(200, 100, 1100), 100e18);

        // Window larger than history clamps to history.
        assertEq(harness.twap(100_000, 100, 1100), 100e18);
    }

    function test_TwoValuesWeightedByTime() public {
        harness.write(100e18, 1000, 16);
        harness.write(200e18, 1100, 16);

        // 100 for 100 seconds, then 200 for 100 seconds: average 150.
        assertEq(harness.twap(1000, 100, 1200), 150e18);

        // One hour after the second write: 100 for 100s and 200 for 3600s.
        // (100*100 + 200*3700) / 3800 = (10000 + 740000) / 3800 = 197.
        assertEq(harness.twap(100_000, 100, 4800), 197368421052631578947);
    }

    function test_CumulativeInterpolatesBetweenObservations() public {
        harness.write(100e18, 1000, 16);
        harness.write(200e18, 1100, 16);

        // Half way through the first value's interval.
        assertEq(harness.cumulativeAt(1050), 5000e18);
        // Exact observation point.
        assertEq(harness.cumulativeAt(1100), 10000e18);
    }

    function test_WindowStartInsideHistoryInterpolates() public {
        harness.write(100e18, 1000, 16);
        harness.write(200e18, 1100, 16);
        harness.write(300e18, 1200, 16);

        // Window 200 ending at 1250 starts at 1050:
        // cumNow = 100*100 + 200*100 + 300*50 = 45000
        // cumStart = 100*50 = 5000
        // twap = 40000 / 200 = 200.
        assertEq(harness.twap(200, 100, 1250), 200e18);
    }

    function test_RingBufferOverwritesOldest() public {
        harness.write(10e18, 1000, 3);
        harness.write(20e18, 1100, 3);
        harness.write(30e18, 1200, 3);
        harness.write(40e18, 1300, 3);

        // History from 1100 to 1400: 20 for 100s, 30 for 100s, 40 for 100s.
        assertEq(harness.twap(1000, 100, 1400), 30e18);

        // Anything before the oldest surviving observation clamps to it.
        assertEq(harness.cumulativeAt(1000), 1000e18);
    }

    function test_MinimumHistoryGuard() public {
        harness.write(100e18, 1000, 16);
        vm.expectRevert(TWAPLib.InsufficientHistory.selector);
        harness.twap(1000, 100, 1050); // only 50 seconds of history
    }

    function test_NoObservationsReverts() public {
        vm.expectRevert(TWAPLib.NoObservations.selector);
        harness.twap(1000, 100, 1050);

        vm.expectRevert(TWAPLib.NoObservations.selector);
        harness.cumulativeAt(1000);
    }

    function test_TimestampsMustIncrease() public {
        harness.write(100e18, 1000, 16);

        vm.expectRevert(TWAPLib.TimestampNotMonotonic.selector);
        harness.write(200e18, 1000, 16);

        vm.expectRevert(TWAPLib.TimestampNotMonotonic.selector);
        harness.write(200e18, 999, 16);
    }

    function test_CapacityZeroRejected() public {
        vm.expectRevert(TWAPLib.InvalidCapacity.selector);
        harness.write(100e18, 1000, 0);
    }
}
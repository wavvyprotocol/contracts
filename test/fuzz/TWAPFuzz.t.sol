// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { TWAPLib } from "../../contracts/lib/TWAPLib.sol";

contract TWAPFuzzHarness {
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

contract TWAPFuzzTest is Test {
    TWAPFuzzHarness internal harness;

    function setUp() public {
        harness = new TWAPFuzzHarness();
    }

    function testFuzz_TwoPointAverageIsMidpoint(uint96 valueSeed1, uint96 valueSeed2, uint32 spanSeed) public {
        uint256 v1 = bound(uint256(valueSeed1), 1, 1e30);
        uint256 v2 = bound(uint256(valueSeed2), 1, 1e30);
        uint64 span = uint64(bound(uint256(spanSeed), 1, 1e6));

        harness.write(v1, 1_000, 16);
        harness.write(v2, uint64(1_000 + span), 16);

        // Equal spans on both sides make the average the arithmetic midpoint.
        uint256 twap = harness.twap(uint64(uint256(span) * 2), 1, uint64(uint256(1_000) + 2 * uint256(span)));
        assertApproxEqAbs(twap, (v1 + v2) / 2, 1);
    }

    function testFuzz_WindowClampsToAvailableHistory(uint96 valueSeed, uint32 spanSeed) public {
        uint256 value = bound(uint256(valueSeed), 1, 1e30);
        uint64 span = uint64(bound(uint256(spanSeed), 1, 1e6));
        harness.write(value, 1_000, 16);

        assertEq(harness.twap(type(uint64).max, 1, uint64(1_000 + span)), value);
    }

    function testFuzz_TwapStaysWithinObservedRange(
        uint96 v1Seed,
        uint96 v2Seed,
        uint96 v3Seed,
        uint32 gapSeed
    ) public {
        uint256 v1 = bound(uint256(v1Seed), 1, 1e30);
        uint256 v2 = bound(uint256(v2Seed), 1, 1e30);
        uint256 v3 = bound(uint256(v3Seed), 1, 1e30);
        uint64 gap = uint64(bound(uint256(gapSeed), 1, 1e6));

        harness.write(v1, 1_000, 16);
        harness.write(v2, uint64(1_000 + gap), 16);
        harness.write(v3, uint64(1_000 + 2 * gap), 16);

        uint256 lowest = v1 < v2 ? (v1 < v3 ? v1 : v3) : (v2 < v3 ? v2 : v3);
        uint256 highest = v1 > v2 ? (v1 > v3 ? v1 : v3) : (v2 > v3 ? v2 : v3);

        uint256 twap = harness.twap(uint64(uint256(gap) * 3), 1, uint64(uint256(1_000) + 3 * uint256(gap)));
        assertGe(twap + 1, lowest);
        assertLe(twap, highest + 1);
    }

    function testFuzz_NonIncreasingTimestampsRevert(uint64 first) public {
        uint64 start = uint64(bound(uint256(first), 2, type(uint64).max - 2));

        harness.write(100e18, start, 16);

        vm.expectRevert(TWAPLib.TimestampNotMonotonic.selector);
        harness.write(200e18, start, 16); // same timestamp

        vm.expectRevert(TWAPLib.TimestampNotMonotonic.selector);
        harness.write(200e18, uint64(start - 1), 16); // older timestamp
    }

    function testFuzz_RingKeepsNewestObservations(uint16 capacitySeed, uint16 extraSeed) public {
        uint16 capacity = uint16(bound(uint256(capacitySeed), 2, 16));
        uint16 extra = uint16(bound(uint256(extraSeed), 1, 16));
        uint16 total = capacity + extra;

        for (uint16 i; i < total; ++i) {
            harness.write(uint256(i + 1) * 1e18, uint64(1_000 + i), capacity);
        }

        // The newest capacity observations are values total-capacity+1..total.
        uint256 minRecent = uint256(total - capacity + 1) * 1e18;
        uint256 maxRecent = uint256(total) * 1e18;
        uint64 nowTs = uint64(1_000 + total + 100);
        uint256 twap = harness.twap(capacity, 1, nowTs);

        assertGe(twap + 1, minRecent);
        assertLe(twap, maxRecent + 1);
    }

    function testFuzz_CumulativeIsMonotone(uint32 offsetSeed1, uint32 offsetSeed2) public {
        harness.write(100e18, 1_000, 16);
        harness.write(300e18, 2_000, 16);

        uint64 o1 = uint64(bound(uint256(offsetSeed1), 0, 900));
        uint64 o2 = uint64(bound(uint256(offsetSeed2), 0, 900));
        (uint64 low, uint64 high) = o1 <= o2 ? (o1, o2) : (o2, o1);

        uint256 cumLow = harness.cumulativeAt(uint64(1_000 + low));
        uint256 cumHigh = harness.cumulativeAt(uint64(1_000 + high));
        assertLe(cumLow, cumHigh);
    }
}
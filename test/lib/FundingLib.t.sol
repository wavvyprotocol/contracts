// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { FundingLib } from "../../contracts/lib/FundingLib.sol";

contract FundingHarness {
    FundingLib.State internal state;

    function accrue(uint256 mark, uint256 index, uint256 coefficient, uint256 maxRate, uint256 blockNumber)
        external
        returns (int256)
    {
        return FundingLib.accrue(state, mark, index, coefficient, maxRate, blockNumber);
    }

    function growth() external view returns (int256) {
        return state.growth;
    }

    function lastBlock() external view returns (uint256) {
        return state.lastBlock;
    }
}

contract FundingLibTest is Test {
    FundingHarness internal harness;

    uint256 internal constant K = 1e18;
    uint256 internal constant MAX_RATE = 1e15; // 0.1 percent per block

    function setUp() public {
        harness = new FundingHarness();
    }

    function test_RateAtTheClamp() public pure {
        // mark is 0.1 percent above index: ratio 1e15, rate 1e15.
        assertEq(FundingLib.ratePerBlock(1001e18, 1000e18, K, MAX_RATE), 1e15);
    }

    function test_RateClampedWhenMoveIsLarge() public pure {
        // 1 percent above index would be 1e16, clamped to 1e15.
        assertEq(FundingLib.ratePerBlock(1010e18, 1000e18, K, MAX_RATE), 1e15);
    }

    function test_RateBelowTheClamp() public pure {
        // 0.2 percent above index with a generous cap: 2e15.
        assertEq(FundingLib.ratePerBlock(1002e18, 1000e18, K, 1e17), 2e15);
    }

    function test_NegativeRateWhenMarkBelowIndex() public pure {
        assertEq(FundingLib.ratePerBlock(999e18, 1000e18, K, MAX_RATE), -1e15);
        assertEq(FundingLib.ratePerBlock(990e18, 1000e18, K, 1e17), -1e16);
    }

    function test_RateZeroCases() public pure {
        assertEq(FundingLib.ratePerBlock(1000e18, 1000e18, K, MAX_RATE), 0); // at parity
        assertEq(FundingLib.ratePerBlock(1010e18, 1000e18, 0, MAX_RATE), 0); // no coefficient
        assertEq(FundingLib.ratePerBlock(1010e18, 1000e18, K, 0), 0); // funding off
        assertEq(FundingLib.ratePerBlock(1010e18, 0, K, MAX_RATE), 0); // no index
    }

    function test_AccrueAdvancesByRateTimesBlocks() public {
        // First call only records the starting block.
        int256 growth = harness.accrue(1001e18, 1000e18, K, MAX_RATE, 100);
        assertEq(growth, 0);
        assertEq(harness.growth(), 0);
        assertEq(harness.lastBlock(), 100);

        // 100 blocks at 1e15 per block: growth 1e17.
        growth = harness.accrue(1001e18, 1000e18, K, MAX_RATE, 200);
        assertEq(growth, 1e17);
        assertEq(harness.growth(), 1e17);

        // Same block again: nothing changes.
        growth = harness.accrue(1001e18, 1000e18, K, MAX_RATE, 200);
        assertEq(growth, 1e17);
        assertEq(harness.lastBlock(), 200);

        // Parity after 100 more blocks: rate is zero, growth holds.
        growth = harness.accrue(1000e18, 1000e18, K, MAX_RATE, 300);
        assertEq(growth, 1e17);
        assertEq(harness.lastBlock(), 300);
    }

    function test_AccrueAccumulatesNegativeRate() public {
        harness.accrue(999e18, 1000e18, K, MAX_RATE, 100);
        int256 growth = harness.accrue(999e18, 1000e18, K, MAX_RATE, 200);
        assertEq(growth, -1e17); // -1e15 * 100 blocks
    }

    function test_PaymentSigns() public pure {
        // Position pays when its checkpoint is below the current growth.
        assertEq(FundingLib.payment(1e18, 1.1e17, 1e17), 1e16);
        // Position receives when growth moved down.
        assertEq(FundingLib.payment(2e18, 1e17, 1.1e17), -2e16);
        // No movement, no payment.
        assertEq(FundingLib.payment(1e18, 1e17, 1e17), 0);
    }
}
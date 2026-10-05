// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { FundingLib } from "../../contracts/lib/FundingLib.sol";
import { WavvyMath } from "../../contracts/lib/WavvyMath.sol";

contract FundingFuzzHarness {
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
}

contract FundingFuzzTest is Test {
    FundingFuzzHarness internal harness;

    function setUp() public {
        harness = new FundingFuzzHarness();
    }

    function testFuzz_RateNeverExceedsCap(uint96 markSeed, uint96 indexSeed, uint96 kSeed, uint96 maxSeed) public pure {
        uint256 mark = bound(uint256(markSeed), 1, 1e30);
        uint256 index = bound(uint256(indexSeed), 1, 1e30);
        uint256 k = bound(uint256(kSeed), 0, 1e20);
        uint256 maxRate = bound(uint256(maxSeed), 0, 1e20);

        int256 rate = FundingLib.ratePerBlock(mark, index, k, maxRate);
        assertLe(WavvyMath.absSigned(rate), maxRate);
    }

    function testFuzz_RateSignFollowsMarkGap(uint96 indexSeed, uint96 deltaSeed, uint96 kSeed) public pure {
        uint256 index = bound(uint256(indexSeed), 1e6, 1e30);
        uint256 delta = bound(uint256(deltaSeed), 1, index);
        uint256 k = bound(uint256(kSeed), 1, 1e20);
        uint256 maxRate = 1e30; // never clamps, so the sign is visible

        int256 above = FundingLib.ratePerBlock(index + delta, index, k, maxRate);
        int256 below = FundingLib.ratePerBlock(index - delta, index, k, maxRate);
        assertGe(above, 0);
        assertLe(below, 0);
    }

    function testFuzz_GrowthEqualsRateTimesBlocks(uint96 indexSeed, uint96 deltaSeed, uint96 blocksSeed) public {
        uint256 index = bound(uint256(indexSeed), 1e6, 1e30);
        uint256 mark = index + bound(uint256(deltaSeed), 0, index);
        uint256 k = 1e18;
        uint256 maxRate = 1e15;
        uint256 blocks = bound(uint256(blocksSeed), 1, 100_000);

        harness.accrue(mark, index, k, maxRate, 1_000);
        int256 growth0 = harness.growth();
        int256 growth1 = harness.accrue(mark, index, k, maxRate, 1_000 + blocks);

        int256 rate = FundingLib.ratePerBlock(mark, index, k, maxRate);
        assertEq(growth1 - growth0, rate * int256(blocks));
    }

    function testFuzz_FirstAccrualIsNoOp(uint96 blockSeed) public {
        uint256 blockNumber = bound(uint256(blockSeed), 1, type(uint64).max);
        int256 growth = harness.accrue(1010e18, 1000e18, 1e18, 1e15, blockNumber);
        assertEq(growth, 0);
        assertEq(harness.growth(), 0);
    }

    function testFuzz_PaymentLinearInSize(uint96 sizeSeed, uint96 deltaSeed) public pure {
        uint256 size = bound(uint256(sizeSeed), 0, 1e30);
        int256 delta = int256(bound(uint256(deltaSeed), 1, 1e18));

        int256 single = FundingLib.payment(size, delta, 0);
        int256 doubled = FundingLib.payment(2 * size, delta, 0);
        assertApproxEqAbs(doubled, 2 * single, 1);
    }
}
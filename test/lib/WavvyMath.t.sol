// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { WavvyMath } from "../../contracts/lib/WavvyMath.sol";

contract WavvyMathTest is Test {
    function test_ToWad() public pure {
        assertEq(WavvyMath.toWad(1_000_000, 6), 1e18); // 1 USDC at 6 decimals
        assertEq(WavvyMath.toWad(5, 0), 5e18);
        assertEq(WavvyMath.toWad(7, 18), 7);
    }

    function test_ToWadRejectsOversizedDecimals() public {
        vm.expectRevert(WavvyMath.UnsupportedDecimals.selector);
        this.toWadExternal(1, 19);
    }

    function toWadExternal(uint256 amount, uint8 decimals) external pure returns (uint256) {
        return WavvyMath.toWad(amount, decimals);
    }

    function test_FromWad() public pure {
        assertEq(WavvyMath.fromWad(1e18, 6), 1_000_000);
        assertEq(WavvyMath.fromWad(1500000000000000000, 6), 1_500_000);
        assertEq(WavvyMath.fromWad(7, 18), 7);
        assertEq(WavvyMath.fromWad(999, 6), 0); // below one token unit, floored
    }

    function test_FromWadRejectsOversizedDecimals() public {
        vm.expectRevert(WavvyMath.UnsupportedDecimals.selector);
        this.fromWadExternal(1, 19);
    }

    function fromWadExternal(uint256 amount, uint8 decimals) external pure returns (uint256) {
        return WavvyMath.fromWad(amount, decimals);
    }

    function test_MulWad() public pure {
        assertEq(WavvyMath.mulWad(2e18, 3e18), 6e18);
        assertEq(WavvyMath.mulWad(5e17, 4e18), 2e18); // 0.5 * 4
        assertEq(WavvyMath.mulWad(1, 1), 0); // sub-wad product truncates
    }

    function test_DivWad() public pure {
        assertEq(WavvyMath.divWad(6e18, 3e18), 2e18);
        assertEq(WavvyMath.divWad(110e18, 100e18), 1.1e18);
        assertEq(WavvyMath.divWad(1e18, 3e18), 333333333333333333); // truncated third
    }

    function test_MulDivFloor() public pure {
        assertEq(WavvyMath.mulDivFloor(7, 3, 2), 10); // 10.5 floored
        assertEq(WavvyMath.mulDivFloor(10, 10, 4), 25);
        assertEq(WavvyMath.mulDivFloor(1, 1, 3), 0);
    }

    function test_MulBps() public pure {
        assertEq(WavvyMath.mulBps(1000e18, 10), 1e18); // 10 bps of 1000
        assertEq(WavvyMath.mulBps(333e18, 3), 99900000000000000); // 9.99e16
    }

    function test_BpsToWad() public pure {
        assertEq(WavvyMath.bpsToWad(10_000), 1e18);
        assertEq(WavvyMath.bpsToWad(1000), 0.1e18);
        assertEq(WavvyMath.bpsToWad(1), 1e14);
    }

    function test_AbsDiffAndDeviation() public pure {
        assertEq(WavvyMath.absDiff(5, 3), 2);
        assertEq(WavvyMath.absDiff(3, 5), 2);
        assertEq(WavvyMath.absDiff(4, 4), 0);

        assertEq(WavvyMath.deviationBps(1050e18, 1000e18), 500); // +5 percent
        assertEq(WavvyMath.deviationBps(950e18, 1000e18), 500); // -5 percent
        assertEq(WavvyMath.deviationBps(1000e18, 1000e18), 0);
        assertEq(WavvyMath.deviationBps(1e18, 0), type(uint256).max);
    }

    function test_MinMax() public pure {
        assertEq(WavvyMath.min(3, 5), 3);
        assertEq(WavvyMath.max(3, 5), 5);
        assertEq(WavvyMath.min(4, 4), 4);
    }

    function test_ClampSigned() public pure {
        assertEq(WavvyMath.clampSigned(-5, -3, 3), -3);
        assertEq(WavvyMath.clampSigned(10, -3, 3), 3);
        assertEq(WavvyMath.clampSigned(1, -3, 3), 1);
        assertEq(WavvyMath.clampSigned(3, -3, 3), 3);
    }

    function test_SignedConversions() public pure {
        assertEq(WavvyMath.toUnsigned(5), 5);
        assertEq(WavvyMath.absSigned(-7), 7);
        assertEq(WavvyMath.absSigned(7), 7);
        assertEq(WavvyMath.signed(9e18), int256(9e18));
    }

    function test_ToUnsignedRejectsNegative() public {
        vm.expectRevert(WavvyMath.NegativeValue.selector);
        this.toUnsignedExternal(-1);
    }

    function toUnsignedExternal(int256 value) external pure returns (uint256) {
        return WavvyMath.toUnsigned(value);
    }

    function test_SignedAddSub() public pure {
        assertEq(WavvyMath.addSigned(2e18, 3e18), 5e18);
        assertEq(WavvyMath.addSigned(2e18, -5e18), -3e18);
        assertEq(WavvyMath.subSigned(2e18, 3e18), -1e18);
        assertEq(WavvyMath.subSigned(-2e18, -3e18), 1e18);
    }

    function test_SignedMulDiv() public pure {
        assertEq(WavvyMath.mulSigned(2e18, 3e18), 6e18);
        assertEq(WavvyMath.mulSigned(-2e18, 3e18), -6e18);
        assertEq(WavvyMath.mulSigned(1e18, -3e18), -3e18);

        assertEq(WavvyMath.divSigned(6e18, 3e18), 2e18);
        assertEq(WavvyMath.divSigned(-6e18, 3e18), -2e18);
        assertEq(WavvyMath.divSigned(1e18, 3e18), 333333333333333333);
    }

    function test_SignedCountHelpers() public pure {
        // 0.05 divided by 2 is 0.025.
        assertEq(WavvyMath.divSignedByCount(0.05e18, 2), 0.025e18);
        // 1e15 per block over 100 blocks is 1e17.
        assertEq(WavvyMath.mulSignedByCount(1e15, 100), 1e17);
        assertEq(WavvyMath.mulSignedByCount(-3e15, 10), -3e16);
    }
}
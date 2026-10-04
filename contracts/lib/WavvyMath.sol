// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { UD60x18, ud, unwrap as udUnwrap } from "@prb/math/src/UD60x18.sol";
import { mul as udMul, div as udDiv } from "@prb/math/src/UD60x18.sol";
import { SD59x18, sd, unwrap as sdUnwrap } from "@prb/math/src/SD59x18.sol";
import {
    mul as sdMul,
    div as sdDiv,
    add as sdAdd,
    sub as sdSub,
    gt as sdGt,
    lt as sdLt,
    isZero as sdIsZero
} from "@prb/math/src/SD59x18.sol";
import { WAD, BPS_DENOMINATOR } from "../utils/Constants.sol";

/// @notice Single entry point for fixed-point math. Business contracts never
/// call PRBMath directly, so rounding conventions stay in one place.
/// Unsigned wad helpers use PRBMath UD60x18 (half-up rounding). Full-precision
/// mulDiv uses OpenZeppelin (floor), and is reserved for places that document it.
library WavvyMath {
    error DivByZero();
    error UnsupportedDecimals();

    /// @notice Scale a token amount with `decimals` up to 18 decimals.
    function toWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) {
            return amount;
        }
        if (decimals > 18) {
            revert UnsupportedDecimals();
        }
        return amount * (10 ** (18 - decimals));
    }

    /// @notice Scale a wad amount down to token units, flooring.
    function fromWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) {
            return amount;
        }
        if (decimals > 18) {
            revert UnsupportedDecimals();
        }
        return amount / (10 ** (18 - decimals));
    }

    /// @notice a * b / 1e18 with PRBMath rounding.
    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return udUnwrap(udMul(ud(a), ud(b)));
    }

    /// @notice a * 1e18 / b with PRBMath rounding. Reverts when b is zero.
    function divWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return udUnwrap(udDiv(ud(a), ud(b)));
    }

    /// @notice a * b / denominator in full precision, flooring. Use where the
    /// intermediate product would overflow the 1e18-scaled path.
    function mulDivFloor(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return Math.mulDiv(a, b, denominator);
    }

    /// @notice amount * bps / 10_000 in full precision, flooring.
    function mulBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, BPS_DENOMINATOR);
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    /// @notice Deviation of `current` from `refValue` in basis points.
    /// A zero reference returns type(uint256).max so callers treat it as invalid.
    function deviationBps(uint256 current, uint256 refValue) internal pure returns (uint256) {
        if (refValue == 0) {
            return type(uint256).max;
        }
        return Math.mulDiv(absDiff(current, refValue), BPS_DENOMINATOR, refValue);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.min(a, b);
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @notice Clamp a signed wad value between lo and hi, both included.
    function clampSigned(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        if (sdLt(sd(x), sd(lo))) {
            return lo;
        }
        if (sdGt(sd(x), sd(hi))) {
            return hi;
        }
        return x;
    }

    function toSigned(uint256 x) internal pure returns (int256) {
        return int256(x);
    }

    /// @notice Convert a signed wad to unsigned, reverting on negative input.
    function toUnsigned(int256 x) internal pure returns (uint256) {
        if (x < 0) {
            revert DivByZero();
        }
        return uint256(x);
    }

    function absSigned(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function isNegative(int256 x) internal pure returns (bool) {
        return sdLt(sd(x), sd(0));
    }

    function addSigned(int256 a, int256 b) internal pure returns (int256) {
        return sdUnwrap(sdAdd(sd(a), sd(b)));
    }

    function subSigned(int256 a, int256 b) internal pure returns (int256) {
        return sdUnwrap(sdSub(sd(a), sd(b)));
    }

    function mulSigned(int256 a, int256 b) internal pure returns (int256) {
        return sdUnwrap(sdMul(sd(a), sd(b)));
    }

    function divSigned(int256 a, int256 b) internal pure returns (int256) {
        return sdUnwrap(sdDiv(sd(a), sd(b)));
    }

    /// @notice a * b / c with a signed result, using SD59x18 semantics.
    function mulDivSigned(int256 a, int256 b, int256 c) internal pure returns (int256) {
        return sdUnwrap(sdDiv(sdMul(sd(a), sd(b)), sd(c)));
    }

    /// @notice Divide a signed wad value by a plain integer count.
    function divSignedByCount(int256 a, uint256 count) internal pure returns (int256) {
        return sdUnwrap(sdDiv(sd(a), sd(int256(count) * int256(WAD))));
    }

    function isZeroSigned(int256 a) internal pure returns (bool) {
        return sdIsZero(sd(a));
    }

    function signed(uint256 x) internal pure returns (int256) {
        return int256(x);
    }
}
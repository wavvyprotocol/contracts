// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// Shared constants. Basis-point math uses a 10,000 denominator.

uint256 constant BPS_DENOMINATOR = 10_000;

// Fixed-point scale used by every Wavvy value: 18 decimals.
uint256 constant WAD = 1e18;

// Index markets start at 1000 points.
uint256 constant INDEX_BASE = 1000e18;

// Lowest index value the protocol will publish. Keeps index and vAMM math
// stable when constituent growth approaches the extreme downside case.
uint256 constant INDEX_FLOOR = 100e18;

// Seconds in a 365-day year. Used only for display-side derivations.
uint256 constant SECONDS_PER_YEAR = 31_536_000;

// Ring buffer capacity per oracle metric. At an hourly interval this is
// roughly 21 days of history, enough for the 7 day music TWAP window.
uint16 constant MAX_OBSERVATIONS = 512;

// A partial liquidation reduces the position until equity covers maintenance
// margin times this buffer. 1.05 leaves a 5 percent cushion against slippage.
uint256 constant LIQUIDATION_TARGET_BUFFER = 1.05e18;
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { WavvyMath } from "./WavvyMath.sol";

/// @notice Cumulative funding index math. The funding rate is clamp(k * (mark - index) / index, -maxRate, +maxRate) per block and the index grows by rate * elapsed blocks. Positions settle with size * (growth - lastGrowth), so no loop over positions is ever needed.
library FundingLib {
    struct State {
        int256 growth;
        uint256 lastBlock;
    }

    /// @notice Per-block funding rate in wad. Positive means mark is above the
    /// index, so longs pay shorts.
    function ratePerBlock(uint256 mark, uint256 index, uint256 coefficient, uint256 maxRatePerBlock)
        internal
        pure
        returns (int256)
    {
        if (index == 0 || coefficient == 0 || maxRatePerBlock == 0) {
            return 0;
        }
        int256 diff = WavvyMath.subSigned(WavvyMath.signed(mark), WavvyMath.signed(index));
        if (diff == 0) {
            return 0;
        }
        int256 ratio = WavvyMath.divSigned(diff, WavvyMath.signed(index));
        int256 rate = WavvyMath.mulSigned(ratio, WavvyMath.signed(coefficient));
        return WavvyMath.clampSigned(rate, -int256(maxRatePerBlock), int256(maxRatePerBlock));
    }

    /// @notice Advance the cumulative funding index to `blockNumber`.
    /// The first call only records the starting block.
    function accrue(
        State storage self,
        uint256 mark,
        uint256 index,
        uint256 coefficient,
        uint256 maxRatePerBlock,
        uint256 blockNumber
    ) internal returns (int256 growth) {
        if (self.lastBlock == 0) {
            self.lastBlock = blockNumber;
            return self.growth;
        }
        uint256 blocks = blockNumber - self.lastBlock;
        if (blocks == 0) {
            return self.growth;
        }
        self.lastBlock = blockNumber;
        int256 rate = ratePerBlock(mark, index, coefficient, maxRatePerBlock);
        if (rate != 0) {
            self.growth = WavvyMath.addSigned(self.growth, WavvyMath.mulSignedByCount(rate, blocks));
        }
        return self.growth;
    }

    /// @notice Funding cost for a position between two index values. Positive
    /// means the position pays; negative means it receives.
    function payment(uint256 size, int256 growth, int256 lastGrowth) internal pure returns (int256) {
        int256 delta = WavvyMath.subSigned(growth, lastGrowth);
        return WavvyMath.mulSigned(WavvyMath.signed(size), delta);
    }
}
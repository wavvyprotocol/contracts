// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Trading surface. Position ownership always resolves to the current
/// NFT holder at call time.
interface IWavvyHouse {
    /// @notice Open a position with `margin` wad at up to `leverage` wad.
    /// `callId` carries an optional curator copy attribution, zero when none.
    function openPosition(uint256 marketId, bool isLong, uint256 margin, uint256 leverage, uint256 callId)
        external
        returns (uint256 tokenId);

    /// @notice Close `closeSize` wad of a position. Closing the full size
    /// burns the token.
    function closePosition(uint256 tokenId, uint256 closeSize) external returns (uint256 payout);

    /// @notice Liquidate an unhealthy position. Permissionless.
    function liquidate(uint256 tokenId) external returns (uint256 payout, uint256 closedSize);
}
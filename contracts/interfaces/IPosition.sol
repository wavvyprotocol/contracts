// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Position ledger. One token per open position, margin, size, entry price, and the funding checkpoint are attached to the token, so ownership
/// follows the NFT holder and transfers never move accounting.
interface IPosition {
    struct PositionData {
        uint256 marketId;
        bool isLong;
        uint256 size;
        uint256 entryPrice;
        uint256 margin;
        int256 lastFundingGrowth;
        uint64 openedAt;
        uint256 callId;
    }

    function mintPosition(address to, PositionData calldata data) external returns (uint256 tokenId);

    function burnPosition(uint256 tokenId) external;

    function updatePosition(uint256 tokenId, uint256 size, uint256 margin, int256 lastFundingGrowth) external;

    function getPosition(uint256 tokenId) external view returns (PositionData memory);

    function ownerOf(uint256 tokenId) external view returns (address);

    function exists(uint256 tokenId) external view returns (bool);

    /// @notice Sum of margins over open positions. The vault account of the
    /// position contract holds this amount.
    function totalMargin() external view returns (uint256);
}
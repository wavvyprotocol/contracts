// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice vAMM surface. Prices are wad, sizes are wad synthetic units.
interface IWavvyAMM {
    struct Market {
        uint256 baseReserve;
        uint256 quoteReserve;
        int256 fundingGrowth;
        uint256 lastFundingBlock;
        uint256 openInterestLong;
        uint256 openInterestShort;
        bool exists;
    }

    /// @notice Create a market with an initial price and virtual base depth.
    function createMarket(uint256 marketId, uint256 initialPrice, uint256 virtualDepth) external;

    /// @notice Execute an opening trade and return the average execution price.
    function openTrade(uint256 marketId, bool isLong, uint256 size, uint256 indexPrice)
        external
        returns (uint256 entryPrice);

    /// @notice Execute a closing trade and return the average execution price.
    function closeTrade(uint256 marketId, bool isLong, uint256 size, uint256 indexPrice)
        external
        returns (uint256 exitPrice);

    /// @notice Advance the cumulative funding index to the current block.
    function accrueFunding(uint256 marketId, uint256 indexPrice) external returns (int256 growth);

    /// @notice Average execution price for a trade without mutating state.
    function previewTrade(uint256 marketId, bool isLong, uint256 size, bool isOpen)
        external
        view
        returns (uint256 price);

    function markPrice(uint256 marketId) external view returns (uint256);

    function fundingGrowth(uint256 marketId) external view returns (int256);

    function openInterest(uint256 marketId) external view returns (uint256 long, uint256 short);

    function marketExists(uint256 marketId) external view returns (bool);

    function getMarket(uint256 marketId) external view returns (Market memory);
}
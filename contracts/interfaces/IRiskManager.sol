// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Risk parameter source. The house and the vAMM read every limit from here instead of carrying their own copies, so one timelocked change moves the whole system.
interface IRiskManager {
    function isMarketPaused(uint256 marketId) external view returns (bool);

    /// @notice Maximum leverage in wad
    function maxLeverage(uint256 marketId) external view returns (uint256);

    /// @notice Minimum margin in wad, a dust guard.
    function minMargin(uint256 marketId) external view returns (uint256);

    /// @notice Open interest cap in wad notional.
    function openInterestCap(uint256 marketId) external view returns (uint256);

    /// @notice Maintenance margin in basis points of notional.
    function maintenanceMarginBps(uint256 marketId) external view returns (uint256);

    /// @notice Liquidation penalty in basis points of the closed notional.
    function liquidationPenaltyBps(uint256 marketId) external view returns (uint256);

    /// @notice Share of the liquidation penalty paid to the liquidator, in
    /// basis points. The remainder goes to the insurance fund.
    function liquidatorShareBps(uint256 marketId) external view returns (uint256);

    /// @notice Trading fee in basis points of notional, charged on open and
    /// close.
    function tradingFeeBps(uint256 marketId) external view returns (uint256);

    /// @notice Mark-versus-index deviation that blocks opens, in basis points.
    function markDeviationPauseBps(uint256 marketId) external view returns (uint256);

    /// @notice Funding coefficient k in wad.
    function fundingCoefficient(uint256 marketId) external view returns (uint256);

    /// @notice Funding rate cap per block in wad. Derived from an annualized
    /// target offchain; never hardcoded onchain.
    function maxFundingRatePerBlock(uint256 marketId) external view returns (uint256);

    /// @notice Share of the trading fee escrowed for the underlying creators,
    /// in basis points.
    function creatorShareBps(uint256 marketId) external view returns (uint256);

    /// @notice Copy fee on copier net profit, in basis points.
    function copyFeeBps(uint256 marketId) external view returns (uint256);

    /// @notice Share of the copy fee paid to the curator, in basis points. The
    /// remainder goes to the protocol.
    function curatorShareBps(uint256 marketId) external view returns (uint256);
}
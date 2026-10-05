// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Curator registry surface used by the house: copy attribution, copy fee accrual, and call lookup.
interface IWavvyCurator {
    /// @notice Record that a position mirrors a call.
    function recordCopy(uint256 callId, uint256 tokenId) external;

    /// @notice Credit a curator's claimable balance with a copy fee share.
    function creditCopyFee(uint256 callId, uint256 amount) external;

    /// @notice Call mirrored by a position, zero when none.
    function attributionOf(uint256 tokenId) external view returns (uint256);

    /// @notice Curator who owns a call.
    function callCurator(uint256 callId) external view returns (address);
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Index market surface. The index value is computed from constituent metric TWAPs and is 18-decimal fixed point.
interface IWavvyIndexOracle {
    /// @notice Current index value. `valid` is false when no constituent is
    /// usable, in which case the value is zero and must not be traded against.
    function indexValue(uint256 marketId) external view returns (uint256 value, bool valid);

    function constituentCount(uint256 marketId) external view returns (uint256);

    function constituent(uint256 marketId, uint256 index)
        external
        view
        returns (bytes32 metricId, uint256 baseline, bool frozen);
}
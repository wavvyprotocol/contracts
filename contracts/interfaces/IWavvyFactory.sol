// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Market registry surface. Markets are created by the protocol, and the registry carries the metadata other contracts read: market type, metric,and the creators who share the fee.
interface IWavvyFactory {
    function marketExists(uint256 marketId) external view returns (bool);

    function marketTypeOf(uint256 marketId) external view returns (uint8);

    function metricOf(uint256 marketId) external view returns (bytes32);

    function creatorIdsOf(uint256 marketId) external view returns (bytes32[] memory);
}
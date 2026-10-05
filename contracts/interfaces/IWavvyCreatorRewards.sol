// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Creator fee escrow surface. Fees accrue per creator id, the creator proves control offchain, links a wallet, and pulls the balance.
interface IWavvyCreatorRewards {
    function accrue(bytes32 creatorId, uint256 amount) external;
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Insurance fund surface. Backstops bad debt and payout shortfalls.
interface IWavvyInsurance {
    function coverBadDebt(uint256 amount) external returns (uint256 covered);
}
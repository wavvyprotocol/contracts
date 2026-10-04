// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice USDC custody and internal margin accounting.
interface IWavvyVault {
    function token() external view returns (IERC20);

    function tokenDecimals() external view returns (uint8);

    /// @notice Internal wad balance of an account.
    function balanceOf(address account) external view returns (uint256);

    function totalBalances() external view returns (uint256);

    /// @notice Deposit `amount` token units and credit the caller.
    function deposit(uint256 amount) external;

    /// @notice Withdraw `amount` token units from the caller's balance.
    function withdraw(uint256 amount) external;

    /// @notice Move `amount` wad between internal accounts. The caller must be `from` or hold the house role.
    function transfer(address from, address to, uint256 amount) external;
}
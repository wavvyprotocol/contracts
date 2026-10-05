// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IWavvyInsurance } from "../interfaces/IWavvyInsurance.sol";
import { IWavvyVault } from "../interfaces/IWavvyVault.sol";
import { WavvyMath } from "../lib/WavvyMath.sol";

/// @notice Insurance fund. Holds its balance in the vault under its own account and pays bad debt or payout shortfalls back to the caller.
///
/// The covered total is tracked so the dashboard can show how much of the fund has been consumed and coverage relative to open interest.
contract WavvyInsurance is AccessControl, IWavvyInsurance {
    using SafeERC20 for IERC20;

    bytes32 public constant HOUSE_ROLE = keccak256("HOUSE_ROLE");

    IWavvyVault public immutable vault;

    uint256 public totalCovered;

    error ZeroAmount();
    error HouseOnly();

    event Funded(address indexed from, uint256 amount);
    event Covered(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(IWavvyVault vault_, address admin) {
        vault = vault_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Deposit into the fund. Pulls tokens from the caller and credits this contract's vault account.
    function fund(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = vault.token();
        token.safeTransferFrom(msg.sender, address(this), amount);
        token.forceApprove(address(vault), amount);
        vault.deposit(amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Move up to `amount` from the fund to the caller. House only, because the caller is the trading system settling a shortfall.
    function coverBadDebt(uint256 amount) external override onlyRole(HOUSE_ROLE) returns (uint256 covered) {
        uint256 fundBalance = vault.balanceOf(address(this));
        covered = WavvyMath.min(amount, fundBalance);
        if (covered > 0) {
            totalCovered += covered;
            vault.transfer(address(this), msg.sender, covered);
            emit Covered(msg.sender, covered);
        }
    }

    /// @notice Withdraw part of the fund back to the treasury account. Admin only, used when the fund exceeds its coverage target.
    function withdraw(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmount();
        vault.transfer(address(this), to, amount);
        emit Withdrawn(to, amount);
    }

    function balance() external view returns (uint256) {
        return vault.balanceOf(address(this));
    }
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IWavvyVault } from "../interfaces/IWavvyVault.sol";
import { WavvyMath } from "../lib/WavvyMath.sol";

/// @notice USDC custody and internal margin accounting for every protocol account: users, the position ledger, the treasury, the insurance fund, and creator/curator escrows.
///
/// Balances are 18-decimal fixed point while the token has its own decimals, deposits and withdrawals convert at the boundary.
/// Token movements always mirror internal movements, so the invariant token.balanceOf(this) >= totalBalances holds at all times.
contract WavvyVault is AccessControl, ReentrancyGuard, IWavvyVault {
    using SafeERC20 for IERC20;

    bytes32 public constant HOUSE_ROLE = keccak256("HOUSE_ROLE");
    /// @notice Protocol contracts that may pull a user's free balance into
    /// their own account during their own user-triggered flows (for example a
    /// curator locking a stake). They can never move funds to a third party.
    bytes32 public constant SYSTEM_ROLE = keccak256("SYSTEM_ROLE");

    IERC20 public immutable token;
    uint8 public immutable tokenDecimals;

    mapping(address => uint256) public balanceOf;
    uint256 public totalBalances;

    error ZeroAmount();
    error InsufficientBalance();
    error UnauthorizedTransfer();
    error UnsupportedDecimals();

    event Deposited(address indexed account, uint256 amountToken, uint256 amountWad);
    event Withdrawn(address indexed account, uint256 amountToken, uint256 amountWad);
    event Transferred(address indexed from, address indexed to, uint256 amountWad);

    constructor(IERC20 token_, address admin) {
        token = token_;
        uint8 decimals = IERC20Metadata(address(token_)).decimals();
        if (decimals > 18) revert UnsupportedDecimals();
        tokenDecimals = decimals;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Deposit `amount` token units and credit the caller.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 wad = WavvyMath.toWad(amount, tokenDecimals);
        balanceOf[msg.sender] += wad;
        totalBalances += wad;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, wad);
    }

    /// @notice Withdraw `amount` token units from the caller's balance.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 wad = WavvyMath.toWad(amount, tokenDecimals);
        uint256 balance = balanceOf[msg.sender];
        if (balance < wad) revert InsufficientBalance();
        balanceOf[msg.sender] = balance - wad;
        totalBalances -= wad;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, wad);
    }

    /// @notice Move `amount` wad between internal accounts. A caller may move its
    /// own balance; the house role may move any account because it settles
    /// positions, liquidations, and fees; a system contract may pull a user's
    /// free balance into its own account only.
    function transfer(address from, address to, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAmount();
        bool isSelf = msg.sender == from;
        bool isHouse = hasRole(HOUSE_ROLE, msg.sender);
        bool isSystemPull = !isHouse && to == msg.sender && hasRole(SYSTEM_ROLE, msg.sender);
        if (!isSelf && !isHouse && !isSystemPull) revert UnauthorizedTransfer();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;
        emit Transferred(from, to, amount);
    }

    /// @notice Token units held by the vault. Always at least `totalBalances`;
    /// the difference is rounding dust from decimal conversions.
    function totalBacking() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
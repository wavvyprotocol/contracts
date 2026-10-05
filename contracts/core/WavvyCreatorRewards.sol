// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IWavvyCreatorRewards } from "../interfaces/IWavvyCreatorRewards.sol";
import { IWavvyVault } from "../interfaces/IWavvyVault.sol";

/// @notice Creator fee escrow. Trading fees accrue per creator id, the creator proves control of the social account offchain, an operator links the verified wallet, and the creator pulls the balance.
///
/// Nobody pushes funds to an unknown address, and nothing is claimable until a wallet is linked.
/// A balance untouched for the claim window can be swept to the creator grants pool.
contract WavvyCreatorRewards is AccessControl, IWavvyCreatorRewards {
    bytes32 public constant HOUSE_ROLE = keccak256("HOUSE_ROLE");

    uint64 public constant DEFAULT_CLAIM_WINDOW = 365 days;
    uint64 public constant DEFAULT_WALLET_CHANGE_DELAY = 48 hours;

    IWavvyVault public immutable vault;

    struct Creator {
        address wallet;
        address pendingWallet;
        uint64 pendingSince;
        uint256 balance;
        uint64 lastAccrualAt;
    }

    mapping(bytes32 => Creator) private _creators;

    uint64 public claimWindow = DEFAULT_CLAIM_WINDOW;
    uint64 public walletChangeDelay = DEFAULT_WALLET_CHANGE_DELAY;
    address public grantsPool;

    error ZeroAmount();
    error NoWalletLinked();
    error NotCreatorWallet();
    error WalletAlreadyLinked();
    error NoPendingWallet();
    error WalletChangePending();
    error ClaimWindowActive();
    error NothingToSweep();
    error InvalidAddress();
    error InvalidParams();

    event Accrued(bytes32 indexed creatorId, uint256 amount);
    event WalletLinked(bytes32 indexed creatorId, address indexed wallet);
    event WalletChangeRequested(bytes32 indexed creatorId, address indexed wallet, uint64 executableAt);
    event WalletChangeFinalized(bytes32 indexed creatorId, address indexed wallet);
    event WalletChangeCancelled(bytes32 indexed creatorId);
    event Claimed(bytes32 indexed creatorId, address indexed wallet, uint256 amount);
    event Swept(bytes32 indexed creatorId, address indexed grantsPool, uint256 amount);
    event ClaimWindowUpdated(uint64 claimWindow);
    event WalletChangeDelayUpdated(uint64 walletChangeDelay);
    event GrantsPoolUpdated(address indexed grantsPool);

    constructor(IWavvyVault vault_, address grantsPool_, address admin) {
        vault = vault_;
        grantsPool = grantsPool_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Accrue a creator fee share. House only, the funds must already be in this contract's vault account.
    function accrue(bytes32 creatorId, uint256 amount) external override onlyRole(HOUSE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        Creator storage creator = _creators[creatorId];
        creator.balance += amount;
        creator.lastAccrualAt = uint64(block.timestamp);
        emit Accrued(creatorId, amount);
    }

    /// @notice Link the verified wallet of a creator. The first link is immediate, replacements must go through the delayed change flow.
    function linkWallet(bytes32 creatorId, address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (wallet == address(0)) revert InvalidAddress();
        Creator storage creator = _creators[creatorId];
        if (creator.wallet != address(0)) revert WalletAlreadyLinked();
        creator.wallet = wallet;
        emit WalletLinked(creatorId, wallet);
    }

    /// @notice Start a wallet replacement. It can be finalized after the wallet change delay, which gives a dispute window on compromised links.
    function requestWalletChange(bytes32 creatorId, address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (wallet == address(0)) revert InvalidAddress();
        Creator storage creator = _creators[creatorId];
        if (creator.wallet == address(0)) revert NoWalletLinked();
        creator.pendingWallet = wallet;
        creator.pendingSince = uint64(block.timestamp);
        emit WalletChangeRequested(creatorId, wallet, uint64(block.timestamp) + walletChangeDelay);
    }

    function finalizeWalletChange(bytes32 creatorId) external {
        Creator storage creator = _creators[creatorId];
        if (creator.pendingWallet == address(0)) revert NoPendingWallet();
        if (block.timestamp < creator.pendingSince + walletChangeDelay) revert WalletChangePending();
        creator.wallet = creator.pendingWallet;
        creator.pendingWallet = address(0);
        creator.pendingSince = 0;
        emit WalletChangeFinalized(creatorId, creator.wallet);
    }

    /// @notice Pull the escrowed balance. Only the linked wallet can claim.
    function claim(bytes32 creatorId) external returns (uint256 amount) {
        Creator storage creator = _creators[creatorId];
        if (creator.wallet == address(0)) revert NoWalletLinked();
        if (msg.sender != creator.wallet) revert NotCreatorWallet();
        amount = creator.balance;
        if (amount == 0) revert ZeroAmount();
        creator.balance = 0;
        vault.transfer(address(this), creator.wallet, amount);
        emit Claimed(creatorId, creator.wallet, amount);
    }

    /// @notice Sweep a dormant balance to the grants pool. Allowed once the
    /// claim window has passed with no new accrual, so active creators are
    /// never swept mid-stream.
    function sweep(bytes32 creatorId) external returns (uint256 amount) {
        Creator storage creator = _creators[creatorId];
        if (creator.lastAccrualAt == 0 || block.timestamp <= uint256(creator.lastAccrualAt) + claimWindow) {
            revert ClaimWindowActive();
        }
        amount = creator.balance;
        if (amount == 0) revert NothingToSweep();
        creator.balance = 0;
        vault.transfer(address(this), grantsPool, amount);
        emit Swept(creatorId, grantsPool, amount);
    }

    /// @notice Cancel a pending wallet replacement before it is finalized.
    function cancelWalletChange(bytes32 creatorId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Creator storage creator = _creators[creatorId];
        if (creator.pendingWallet == address(0)) revert NoPendingWallet();
        creator.pendingWallet = address(0);
        creator.pendingSince = 0;
        emit WalletChangeCancelled(creatorId);
    }

    function setClaimWindow(uint64 claimWindow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (claimWindow_ == 0) revert InvalidParams();
        claimWindow = claimWindow_;
        emit ClaimWindowUpdated(claimWindow_);
    }

    function setWalletChangeDelay(uint64 delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delay == 0) revert InvalidParams();
        walletChangeDelay = delay;
        emit WalletChangeDelayUpdated(delay);
    }

    function setGrantsPool(address grantsPool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (grantsPool_ == address(0)) revert InvalidAddress();
        grantsPool = grantsPool_;
        emit GrantsPoolUpdated(grantsPool_);
    }

    function creatorInfo(bytes32 creatorId)
        external
        view
        returns (address wallet, address pendingWallet, uint256 balance, uint64 lastAccrualAt)
    {
        Creator storage creator = _creators[creatorId];
        return (creator.wallet, creator.pendingWallet, creator.balance, creator.lastAccrualAt);
    }

    function balanceOfCreator(bytes32 creatorId) external view returns (uint256) {
        return _creators[creatorId].balance;
    }
}
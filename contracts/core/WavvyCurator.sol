// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IWavvyCurator } from "../interfaces/IWavvyCurator.sol";
import { IWavvyVault } from "../interfaces/IWavvyVault.sol";

/// @notice Curator registry. Curators publish calls backed by a USDC stake, copiers attach their positions to a call, and copy fees accrue on the curator's claimable balance.
///
/// There is no slashing: a bad call costs reputation (computed offchain), never the stake. The stake is locked while the call is open and released by the curator when it closes.
contract WavvyCurator is AccessControl, IWavvyCurator {
    bytes32 public constant HOUSE_ROLE = keccak256("HOUSE_ROLE");

    IWavvyVault public immutable vault;

    struct Call {
        address curator;
        uint256 marketId;
        bool isLong;
        uint256 stake;
        uint64 createdAt;
        bool active;
    }

    uint256 private _nextCallId = 1;
    mapping(uint256 => Call) private _calls;
    mapping(uint256 => uint256) private _copies;
    mapping(uint256 => uint256) private _attribution;
    mapping(address => uint256) private _claimable;

    error UnknownCall();
    error CallAlreadyClosed();
    error NotCallCurator();
    error StakeRequired();
    error AlreadyAttributed();
    error NothingToClaim();

    event CallCreated(uint256 indexed callId, address indexed curator, uint256 indexed marketId, bool isLong, uint256 stake);
    event CallClosed(uint256 indexed callId, address indexed curator, uint256 stakeReleased);
    event CopyRecorded(uint256 indexed callId, uint256 indexed tokenId, address indexed curator);
    event CopyFeeCredited(uint256 indexed callId, address indexed curator, uint256 amount);
    event Claimed(address indexed curator, uint256 amount);

    constructor(IWavvyVault vault_, address admin) {
        vault = vault_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Publish a call and lock the stake in this contract's vault account.
    function createCall(uint256 marketId, bool isLong, uint256 stake) external returns (uint256 callId) {
        if (stake == 0) revert StakeRequired();
        callId = _nextCallId++;
        _calls[callId] = Call({
            curator: msg.sender,
            marketId: marketId,
            isLong: isLong,
            stake: stake,
            createdAt: uint64(block.timestamp),
            active: true
        });
        vault.transfer(msg.sender, address(this), stake);
        emit CallCreated(callId, msg.sender, marketId, isLong, stake);
    }

    /// @notice Close a call and release the stake to the curator.
    function closeCall(uint256 callId) external {
        Call storage call = _calls[callId];
        if (call.curator == address(0)) revert UnknownCall();
        if (!call.active) revert CallAlreadyClosed();
        if (msg.sender != call.curator) revert NotCallCurator();
        call.active = false;
        vault.transfer(address(this), call.curator, call.stake);
        emit CallClosed(callId, call.curator, call.stake);
    }

    /// @notice Attach a position to a call. House only, called at open time.
    function recordCopy(uint256 callId, uint256 tokenId) external override onlyRole(HOUSE_ROLE) {
        Call storage call = _calls[callId];
        if (call.curator == address(0)) revert UnknownCall();
        if (!call.active) revert CallAlreadyClosed();
        if (_attribution[tokenId] != 0) revert AlreadyAttributed();
        _attribution[tokenId] = callId;
        _copies[callId] += 1;
        emit CopyRecorded(callId, tokenId, call.curator);
    }

    /// @notice Credit a curator's claimable balance with a copy fee share.
    /// House only, the funds must already sit in this contract's vault account.
    function creditCopyFee(uint256 callId, uint256 amount) external override onlyRole(HOUSE_ROLE) {
        address curator = _calls[callId].curator;
        if (curator == address(0)) revert UnknownCall();
        _claimable[curator] += amount;
        emit CopyFeeCredited(callId, curator, amount);
    }

    /// @notice Pull accrued copy fees.
    function claim() external returns (uint256 amount) {
        amount = _claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender] = 0;
        vault.transfer(address(this), msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function attributionOf(uint256 tokenId) external view override returns (uint256) {
        return _attribution[tokenId];
    }

    function callCurator(uint256 callId) external view override returns (address) {
        return _calls[callId].curator;
    }

    function callInfo(uint256 callId)
        external
        view
        returns (address curator, uint256 marketId, bool isLong, uint256 stake, uint64 createdAt, bool active)
    {
        Call storage call = _calls[callId];
        return (call.curator, call.marketId, call.isLong, call.stake, call.createdAt, call.active);
    }

    function copiesOf(uint256 callId) external view returns (uint256) {
        return _copies[callId];
    }

    function claimable(address curator) external view returns (uint256) {
        return _claimable[curator];
    }
}
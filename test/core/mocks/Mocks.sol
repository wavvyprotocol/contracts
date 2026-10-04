// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IPosition } from "../../../contracts/interfaces/IPosition.sol";
import { IRiskManager } from "../../../contracts/interfaces/IRiskManager.sol";
import { IWavvyIndexOracle } from "../../../contracts/interfaces/IWavvyIndexOracle.sol";
import { IWavvyInsurance } from "../../../contracts/interfaces/IWavvyInsurance.sol";
import { IWavvyOracle } from "../../../contracts/interfaces/IWavvyOracle.sol";
import { IWavvyVault } from "../../../contracts/interfaces/IWavvyVault.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle is IWavvyOracle {
    mapping(bytes32 => uint256) private _twaps;
    mapping(bytes32 => bool) private _fresh;

    function set(bytes32 metricId, uint256 twap, bool fresh) external {
        _twaps[metricId] = twap;
        _fresh[metricId] = fresh;
    }

    function getTWAP(bytes32 metricId) external view override returns (uint256) {
        return _twaps[metricId];
    }

    function getTWAP(bytes32 metricId, uint64) external view override returns (uint256) {
        return _twaps[metricId];
    }

    function latestValue(bytes32 metricId) external view override returns (uint256) {
        return _twaps[metricId];
    }

    function lastUpdateAt(bytes32) external pure override returns (uint64) {
        return 0;
    }

    function isFresh(bytes32 metricId) external view override returns (bool) {
        return _fresh[metricId];
    }

    function isSuspended(bytes32) external pure override returns (bool) {
        return false;
    }

    function isFrozen(bytes32) external pure override returns (bool) {
        return false;
    }
}

contract MockIndexOracle is IWavvyIndexOracle {
    mapping(uint256 => uint256) private _values;
    mapping(uint256 => bool) private _valid;

    function set(uint256 marketId, uint256 value, bool valid) external {
        _values[marketId] = value;
        _valid[marketId] = valid;
    }

    function indexValue(uint256 marketId) external view override returns (uint256 value, bool valid) {
        return (_values[marketId], _valid[marketId]);
    }

    function constituentCount(uint256) external pure override returns (uint256) {
        return 0;
    }

    function constituent(uint256, uint256) external pure override returns (bytes32, uint256, bool) {
        return (bytes32(0), 0, false);
    }
}

contract MockRiskManager is IRiskManager {
    struct Config {
        bool paused;
        uint256 maxLeverage;
        uint256 minMargin;
        uint256 openInterestCap;
        uint256 maintenanceMarginBps;
        uint256 liquidationPenaltyBps;
        uint256 liquidatorShareBps;
        uint256 tradingFeeBps;
        uint256 markDeviationPauseBps;
        uint256 fundingCoefficient;
        uint256 maxFundingRatePerBlock;
    }

    mapping(uint256 => Config) private _configs;

    function setConfig(uint256 marketId, Config calldata config) external {
        _configs[marketId] = config;
    }

    function setPaused(uint256 marketId, bool paused) external {
        _configs[marketId].paused = paused;
    }

    function setMaintenanceMarginBps(uint256 marketId, uint256 bps) external {
        _configs[marketId].maintenanceMarginBps = bps;
    }

    function setTradingFeeBps(uint256 marketId, uint256 bps) external {
        _configs[marketId].tradingFeeBps = bps;
    }

    function setOpenInterestCap(uint256 marketId, uint256 cap) external {
        _configs[marketId].openInterestCap = cap;
    }

    function isMarketPaused(uint256 marketId) external view override returns (bool) {
        return _configs[marketId].paused;
    }

    function maxLeverage(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].maxLeverage;
    }

    function minMargin(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].minMargin;
    }

    function openInterestCap(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].openInterestCap;
    }

    function maintenanceMarginBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].maintenanceMarginBps;
    }

    function liquidationPenaltyBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].liquidationPenaltyBps;
    }

    function liquidatorShareBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].liquidatorShareBps;
    }

    function tradingFeeBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].tradingFeeBps;
    }

    function markDeviationPauseBps(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].markDeviationPauseBps;
    }

    function fundingCoefficient(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].fundingCoefficient;
    }

    function maxFundingRatePerBlock(uint256 marketId) external view override returns (uint256) {
        return _configs[marketId].maxFundingRatePerBlock;
    }
}

contract MockPosition is IPosition {
    error NoToken();

    uint256 private _nextId = 1;
    uint256 public totalMargin;

    mapping(uint256 => PositionData) private _positions;
    mapping(uint256 => address) private _owners;
    mapping(uint256 => bool) private _exists;

    function mintPosition(address to, PositionData calldata data) external override returns (uint256 tokenId) {
        tokenId = _nextId++;
        _positions[tokenId] = data;
        _owners[tokenId] = to;
        _exists[tokenId] = true;
        totalMargin += data.margin;
    }

    function burnPosition(uint256 tokenId) external override {
        if (!_exists[tokenId]) revert NoToken();
        totalMargin -= _positions[tokenId].margin;
        delete _positions[tokenId];
        delete _owners[tokenId];
        delete _exists[tokenId];
    }

    function updatePosition(uint256 tokenId, uint256 size, uint256 margin, int256 lastFundingGrowth)
        external
        override
    {
        if (!_exists[tokenId]) revert NoToken();
        PositionData storage p = _positions[tokenId];
        totalMargin = totalMargin - p.margin + margin;
        p.size = size;
        p.margin = margin;
        p.lastFundingGrowth = lastFundingGrowth;
    }

    function getPosition(uint256 tokenId) external view override returns (PositionData memory) {
        if (!_exists[tokenId]) revert NoToken();
        return _positions[tokenId];
    }

    function ownerOf(uint256 tokenId) external view override returns (address) {
        if (!_exists[tokenId]) revert NoToken();
        return _owners[tokenId];
    }

    function exists(uint256 tokenId) external view override returns (bool) {
        return _exists[tokenId];
    }
}

contract MockInsurance is IWavvyInsurance {
    IWavvyVault public immutable vault;

    constructor(IWavvyVault vault_) {
        vault = vault_;
    }

    function coverBadDebt(uint256 amount) external override returns (uint256 covered) {
        uint256 balance = vault.balanceOf(address(this));
        covered = amount < balance ? amount : balance;
        if (covered > 0) {
            vault.transfer(address(this), msg.sender, covered);
        }
    }
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { FundingLib } from "../lib/FundingLib.sol";
import { WavvyMath } from "../lib/WavvyMath.sol";
import { IPosition } from "../interfaces/IPosition.sol";
import { IRiskManager } from "../interfaces/IRiskManager.sol";
import { IWavvyAMM } from "../interfaces/IWavvyAMM.sol";
import { IWavvyHouse } from "../interfaces/IWavvyHouse.sol";
import { IWavvyIndexOracle } from "../interfaces/IWavvyIndexOracle.sol";
import { IWavvyInsurance } from "../interfaces/IWavvyInsurance.sol";
import { IWavvyOracle } from "../interfaces/IWavvyOracle.sol";
import { IWavvyVault } from "../interfaces/IWavvyVault.sol";
import { BPS_DENOMINATOR, LIQUIDATION_TARGET_BUFFER, WAD } from "../utils/Constants.sol";

/// @notice Composes the vault, the vAMM, and the position ledger into open, close, and liquidation flows.
///
/// Position ownership always resolves through the position token's current holder, so a transferred token moves the whole position, margin included.
/// Margin lives in the position contract's vault account, a position has no claim on its opener address after opening.
///
/// PnL is settled against the treasury account with the insurance fund as the backstop, the vault moves value between internal accounts only.
contract WavvyHouse is AccessControl, ReentrancyGuard, IWavvyHouse {
    uint8 internal constant PRICE_SOURCE_METRIC = 0;
    uint8 internal constant PRICE_SOURCE_INDEX = 1;

    struct PriceSource {
        uint8 kind;
        bytes32 metricId;
    }

    IWavvyVault public immutable vault;
    IWavvyAMM public immutable amm;
    IPosition public immutable position;
    IWavvyOracle public immutable oracle;
    IWavvyIndexOracle public immutable indexOracle;
    IRiskManager public immutable risk;
    IWavvyInsurance public immutable insurance;

    address public treasury;
    mapping(uint256 => PriceSource) public priceSources;

    error MarketPaused();
    error MarketUnavailable();
    error LeverageTooLow();
    error LeverageTooHigh();
    error InsufficientMargin();
    error MarkDeviationTooHigh();
    error PositionNotFound();
    error NotNFTOwner();
    error InvalidCloseSize();
    error LiquidationNotAllowed();
    error BelowMaintenanceMargin();
    error PartialCloseNotViable();
    error ProtocolBufferExhausted();
    error InvalidPriceSource();
    error SettlementMismatch();
    error ZeroAmount();

    event PositionOpened(
        uint256 indexed tokenId,
        uint256 indexed marketId,
        address indexed holder,
        bool isLong,
        uint256 size,
        uint256 entryPrice,
        uint256 margin,
        uint256 fee,
        uint256 callId
    );
    event PositionClosed(
        uint256 indexed tokenId,
        address indexed holder,
        uint256 closedSize,
        uint256 exitPrice,
        uint256 payout,
        uint256 fee
    );
    event Liquidated(
        uint256 indexed tokenId,
        address indexed liquidator,
        address indexed holder,
        uint256 closedSize,
        uint256 penalty,
        uint256 payout
    );
    event FundingSettled(uint256 indexed tokenId, int256 fundingCost);
    event BadDebt(uint256 indexed tokenId, uint256 deficit, uint256 covered);
    event TreasuryUpdated(address indexed treasury);
    event PriceSourceSet(uint256 indexed marketId, uint8 kind, bytes32 metricId);

    constructor(
        IWavvyVault vault_,
        IWavvyAMM amm_,
        IPosition position_,
        IWavvyOracle oracle_,
        IWavvyIndexOracle indexOracle_,
        IRiskManager risk_,
        IWavvyInsurance insurance_,
        address treasury_,
        address admin
    ) {
        vault = vault_;
        amm = amm_;
        position = position_;
        oracle = oracle_;
        indexOracle = indexOracle_;
        risk = risk_;
        insurance = insurance_;
        treasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAmount();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @notice Point a market at its price source: a metric TWAP in the metric
    /// oracle, or the index oracle for basket markets.
    function setMarketPriceSource(uint256 marketId, uint8 kind, bytes32 metricId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (kind > PRICE_SOURCE_INDEX) revert InvalidPriceSource();
        if (kind == PRICE_SOURCE_METRIC && metricId == bytes32(0)) revert InvalidPriceSource();
        priceSources[marketId] = PriceSource({ kind: kind, metricId: metricId });
        emit PriceSourceSet(marketId, kind, metricId);
    }

    /// @inheritdoc IWavvyHouse
    function openPosition(uint256 marketId, bool isLong, uint256 margin, uint256 leverage, uint256 callId)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (!amm.marketExists(marketId)) revert MarketUnavailable();
        if (risk.isMarketPaused(marketId)) revert MarketPaused();
        if (!_priceSourceFresh(marketId)) revert MarketUnavailable();
        if (margin == 0 || margin < risk.minMargin(marketId)) revert InsufficientMargin();
        if (leverage < WAD) revert LeverageTooLow();
        if (leverage > risk.maxLeverage(marketId)) revert LeverageTooHigh();

        uint256 indexPrice = _indexPrice(marketId);
        uint256 mark = amm.markPrice(marketId);
        if (WavvyMath.deviationBps(mark, indexPrice) > risk.markDeviationPauseBps(marketId)) {
            revert MarkDeviationTooHigh();
        }

        uint256 notionalWanted = WavvyMath.mulWad(margin, leverage);
        uint256 size = WavvyMath.mulDivFloor(notionalWanted, WAD, mark);
        if (size == 0) revert InsufficientMargin();
        // One refinement pass against price impact keeps the effective
        // leverage at the requested level instead of rejecting the trade.
        size = WavvyMath.mulDivFloor(notionalWanted, WAD, amm.previewTrade(marketId, isLong, size, true));
        if (size == 0) revert InsufficientMargin();

        uint256 entryPrice = amm.openTrade(marketId, isLong, size, indexPrice);
        uint256 notional = WavvyMath.mulWad(size, entryPrice);

        if (WavvyMath.divWad(notional, margin) > risk.maxLeverage(marketId)) revert LeverageTooHigh();
        if (WavvyMath.mulBps(notional, risk.maintenanceMarginBps(marketId)) >= margin) {
            revert BelowMaintenanceMargin();
        }

        uint256 fee = WavvyMath.mulBps(notional, risk.tradingFeeBps(marketId));
        if (vault.balanceOf(msg.sender) < margin + fee) revert InsufficientMargin();

        vault.transfer(msg.sender, address(position), margin);
        if (fee > 0) vault.transfer(msg.sender, treasury, fee);

        tokenId = position.mintPosition(
            msg.sender,
            IPosition.PositionData({
                marketId: marketId,
                isLong: isLong,
                size: size,
                entryPrice: entryPrice,
                margin: margin,
                lastFundingGrowth: amm.fundingGrowth(marketId),
                openedAt: uint64(block.timestamp),
                callId: callId
            })
        );

        emit PositionOpened(tokenId, marketId, msg.sender, isLong, size, entryPrice, margin, fee, callId);
    }

    /// @inheritdoc IWavvyHouse
    function closePosition(uint256 tokenId, uint256 closeSize) external nonReentrant returns (uint256 payout) {
        if (!position.exists(tokenId)) revert PositionNotFound();
        address holder = position.ownerOf(tokenId);
        if (msg.sender != holder) revert NotNFTOwner();

        IPosition.PositionData memory p = position.getPosition(tokenId);
        if (closeSize == 0 || closeSize > p.size) revert InvalidCloseSize();

        uint256 indexPrice = _indexPrice(p.marketId);
        int256 growth = amm.accrueFunding(p.marketId, indexPrice);
        CloseResult memory r = _executeClose(p, closeSize, growth, indexPrice, risk.tradingFeeBps(p.marketId), 0);

        if (closeSize == p.size) {
            position.updatePosition(tokenId, 0, 0, growth);
            payout = _settle(tokenId, holder, p.marketId, r.marginOut, r.pnl, r.fundingCost, r.fee, 0, address(0), true);
            position.burnPosition(tokenId);
        } else {
            position.updatePosition(tokenId, p.size - closeSize, p.margin - r.marginOut, growth);
            payout = _settle(tokenId, holder, p.marketId, r.marginOut, r.pnl, r.fundingCost, r.fee, 0, address(0), false);
        }

        emit FundingSettled(tokenId, r.fundingCost);
        emit PositionClosed(tokenId, holder, closeSize, r.exitPrice, payout, r.fee);
    }

    /// @inheritdoc IWavvyHouse
    function liquidate(uint256 tokenId) external nonReentrant returns (uint256 payout, uint256 closedSize) {
        if (!position.exists(tokenId)) revert PositionNotFound();
        address holder = position.ownerOf(tokenId);
        IPosition.PositionData memory p = position.getPosition(tokenId);

        (uint256 effectiveIndex, int256 growth, uint256 mark) = _liquidationContext(p.marketId);
        if (!_isLiquidatable(p, growth, mark)) revert LiquidationNotAllowed();

        int256 equity = _equity(p, growth, mark);
        uint256 target = equity > 0 ? _targetSize(p, uint256(equity), mark) : 0;
        if (target == 0 || target >= p.size) {
            return _fullLiquidate(tokenId, holder, p, growth, effectiveIndex);
        }

        closedSize = p.size - target;
        CloseResult memory r =
            _executeClose(p, closedSize, growth, effectiveIndex, 0, risk.liquidationPenaltyBps(p.marketId));

        // The closed slice realizes its loss against margin instead of paying
        // the holder: equity stays in the position while notional shrinks,
        // which is what restores the margin ratio.
        int256 marginAfterSigned = WavvyMath.subSigned(
            WavvyMath.addSigned(WavvyMath.signed(p.margin), WavvyMath.subSigned(r.pnl, r.fundingCost)),
            WavvyMath.signed(r.penalty)
        );
        if (marginAfterSigned < 0) revert PartialCloseNotViable();
        uint256 marginAfter = uint256(marginAfterSigned);

        position.updatePosition(tokenId, target, marginAfter, growth);
        _settleSlice(p.marketId, p.margin, marginAfter, r.pnl, r.fundingCost, r.penalty);
        payout = 0;

        emit FundingSettled(tokenId, r.fundingCost);
        emit Liquidated(tokenId, msg.sender, holder, closedSize, r.penalty, payout);

        // Escalate when the reduced position is still unhealthy.
        IPosition.PositionData memory afterData = position.getPosition(tokenId);
        if (_isLiquidatable(afterData, growth, amm.markPrice(p.marketId))) {
            (uint256 payoutRest, uint256 closedRest) =
                _fullLiquidate(tokenId, holder, afterData, growth, effectiveIndex);
            payout += payoutRest;
            closedSize += closedRest;
        }
    }

    /// @dev Shared close math for user closes and liquidations. `feeBps` is the
    /// trading fee on the closed notional; `penaltyBps` is the liquidation
    /// penalty. One of them is zero depending on the flow.
    struct CloseResult {
        uint256 exitPrice;
        int256 pnl;
        int256 fundingCost;
        uint256 marginOut;
        uint256 fee;
        uint256 penalty;
    }

    function _executeClose(
        IPosition.PositionData memory p,
        uint256 closedSize,
        int256 growth,
        uint256 indexPrice,
        uint256 feeBps,
        uint256 penaltyBps
    ) internal returns (CloseResult memory r) {
        r.fundingCost = FundingLib.payment(closedSize, growth, p.lastFundingGrowth);
        r.exitPrice = amm.closeTrade(p.marketId, p.isLong, closedSize, indexPrice);
        r.pnl = _pnl(p.isLong, closedSize, p.entryPrice, r.exitPrice);
        uint256 notional = WavvyMath.mulWad(closedSize, r.exitPrice);
        r.marginOut = WavvyMath.mulDivFloor(p.margin, closedSize, p.size);
        if (feeBps > 0) r.fee = WavvyMath.mulBps(notional, feeBps);
        if (penaltyBps > 0) r.penalty = WavvyMath.mulBps(notional, penaltyBps);
    }

    function _fullLiquidate(
        uint256 tokenId,
        address holder,
        IPosition.PositionData memory p,
        int256 growth,
        uint256 indexPrice
    ) internal returns (uint256 payout, uint256 closedSize) {
        closedSize = p.size;
        CloseResult memory r =
            _executeClose(p, closedSize, growth, indexPrice, 0, risk.liquidationPenaltyBps(p.marketId));

        position.updatePosition(tokenId, 0, 0, growth);
        payout = _settle(tokenId, holder, p.marketId, p.margin, r.pnl, r.fundingCost, 0, r.penalty, msg.sender, true);
        position.burnPosition(tokenId);

        emit FundingSettled(tokenId, r.fundingCost);
        emit Liquidated(tokenId, msg.sender, holder, closedSize, r.penalty, payout);
    }

    /// @dev Funding checkpoint, effective index price, and mark for a
    /// liquidation. A stale or missing index falls back to the mark price so
    /// positions can still be wound down.
    function _liquidationContext(uint256 marketId) internal returns (uint256 effectiveIndex, int256 growth, uint256 mark) {
        (uint256 indexPrice, bool indexValid) = _indexPriceSafe(marketId);
        mark = amm.markPrice(marketId);
        if (indexValid) {
            effectiveIndex = indexPrice;
            growth = amm.accrueFunding(marketId, indexPrice);
        } else {
            effectiveIndex = mark;
            growth = amm.fundingGrowth(marketId);
        }
    }

    /// @dev Settles a liquidation slice where the position keeps its equity:
    /// realized PnL and funding move between the position account and the
    /// treasury, the penalty is debited from margin, and the liquidator and
    /// the insurance fund receive their shares.
    function _settleSlice(
        uint256 marketId,
        uint256 marginBefore,
        uint256 marginAfter,
        int256 pnl,
        int256 fundingCost,
        uint256 penalty
    ) internal {
        int256 net = WavvyMath.subSigned(pnl, fundingCost);
        if (net < 0) {
            vault.transfer(address(position), treasury, WavvyMath.absSigned(net));
        } else if (net > 0) {
            _ensureTreasury(uint256(net));
            vault.transfer(treasury, address(position), uint256(net));
        }
        if (penalty > 0) {
            vault.transfer(address(position), treasury, penalty);
            _payLiquidationShares(marketId, msg.sender, penalty);
        }
        uint256 expected =
            uint256(WavvyMath.subSigned(WavvyMath.addSigned(WavvyMath.signed(marginBefore), net), WavvyMath.signed(penalty)));
        if (expected != marginAfter) revert SettlementMismatch();
    }

    function _payLiquidationShares(uint256 marketId, address liquidator, uint256 penalty) internal {
        uint256 loot = WavvyMath.mulBps(penalty, risk.liquidatorShareBps(marketId));
        uint256 insuranceShare = penalty - loot;
        if (loot > 0) vault.transfer(treasury, liquidator, loot);
        if (insuranceShare > 0) vault.transfer(treasury, address(insurance), insuranceShare);
    }

    /// @dev Moves margin, PnL, funding, fees, and penalties between the
    /// position account, the holder, the treasury, the liquidator, and the
    /// insurance fund. Returns the payout sent to the holder.
    function _settle(
        uint256 tokenId,
        address holder,
        uint256 marketId,
        uint256 marginIn,
        int256 pnl,
        int256 fundingCost,
        uint256 fee,
        uint256 penalty,
        address liquidator,
        bool allowBadDebt
    ) internal returns (uint256 payout) {
        int256 net = WavvyMath.subSigned(
            WavvyMath.subSigned(pnl, fundingCost), WavvyMath.signed(fee + penalty)
        );
        int256 payoutSigned = WavvyMath.addSigned(WavvyMath.signed(marginIn), net);

        if (payoutSigned < 0) {
            if (!allowBadDebt) revert PartialCloseNotViable();
            vault.transfer(address(position), treasury, marginIn);
            uint256 deficit = WavvyMath.absSigned(payoutSigned);
            uint256 covered = insurance.coverBadDebt(deficit);
            if (covered > 0) vault.transfer(address(this), treasury, covered);
            emit BadDebt(tokenId, deficit, covered);
            return 0;
        }

        uint256 payoutOut = uint256(payoutSigned);
        if (net > 0) {
            _ensureTreasury(uint256(net) + penalty);
            vault.transfer(treasury, address(position), uint256(net));
        } else {
            uint256 loss = WavvyMath.absSigned(net);
            vault.transfer(address(position), treasury, loss);
        }
        vault.transfer(address(position), holder, payoutOut);

        if (penalty > 0 && liquidator != address(0)) {
            _payLiquidationShares(marketId, liquidator, penalty);
        }

        return payoutOut;
    }

    /// @dev Ensure the treasury account can cover an outgoing amount, pulling
    /// from the insurance fund when needed.
    function _ensureTreasury(uint256 amount) internal {
        uint256 balance = vault.balanceOf(treasury);
        if (balance >= amount) return;
        uint256 deficit = amount - balance;
        uint256 covered = insurance.coverBadDebt(deficit);
        if (covered < deficit) revert ProtocolBufferExhausted();
        vault.transfer(address(this), treasury, covered);
    }

    function _equity(IPosition.PositionData memory p, int256 growth, uint256 mark)
        internal
        pure
        returns (int256)
    {
        int256 pnl = _pnl(p.isLong, p.size, p.entryPrice, mark);
        int256 fundingCost = FundingLib.payment(p.size, growth, p.lastFundingGrowth);
        return WavvyMath.subSigned(WavvyMath.addSigned(WavvyMath.signed(p.margin), pnl), fundingCost);
    }

    function _isLiquidatable(IPosition.PositionData memory p, int256 growth, uint256 mark)
        internal
        view
        returns (bool)
    {
        int256 equity = _equity(p, growth, mark);
        uint256 maintenance = WavvyMath.mulBps(WavvyMath.mulWad(p.size, mark), risk.maintenanceMarginBps(p.marketId));
        return equity < WavvyMath.signed(maintenance);
    }

    /// @dev Largest size whose equity covers maintenance margin times the
    /// safety buffer, accounting for the penalty on the closed slice.
    function _targetSize(IPosition.PositionData memory p, uint256 equity, uint256 mark)
        internal
        view
        returns (uint256)
    {
        uint256 mmWad = WavvyMath.bpsToWad(risk.maintenanceMarginBps(p.marketId));
        uint256 penaltyWad = WavvyMath.bpsToWad(risk.liquidationPenaltyBps(p.marketId));
        uint256 penaltyPerUnit = WavvyMath.mulWad(mark, penaltyWad);
        uint256 maintenancePerUnit = WavvyMath.mulWad(mark, WavvyMath.mulWad(mmWad, LIQUIDATION_TARGET_BUFFER));
        if (maintenancePerUnit <= penaltyPerUnit) return 0;

        // s' = (e - s * penaltyPerUnit) / (maintenancePerUnit - penaltyPerUnit)
        uint256 penaltyAtFullSize = WavvyMath.mulWad(p.size, penaltyPerUnit);
        if (equity <= penaltyAtFullSize) return 0;
        return ((equity - penaltyAtFullSize) * WAD) / (maintenancePerUnit - penaltyPerUnit);
    }

    function _pnl(bool isLong, uint256 size, uint256 entryPrice, uint256 exitPrice)
        internal
        pure
        returns (int256)
    {
        int256 diff = WavvyMath.subSigned(WavvyMath.signed(exitPrice), WavvyMath.signed(entryPrice));
        int256 value = WavvyMath.mulSigned(WavvyMath.signed(size), diff);
        return isLong ? value : WavvyMath.subSigned(0, value);
    }

    /// @dev Index price for opens. Reverts when the source is unusable, which
    /// blocks opens on stale data.
    function _indexPrice(uint256 marketId) internal view returns (uint256) {
        PriceSource memory source = priceSources[marketId];
        if (source.kind == PRICE_SOURCE_METRIC) {
            return oracle.getTWAP(source.metricId);
        }
        (uint256 value, bool valid) = indexOracle.indexValue(marketId);
        if (!valid) revert MarketUnavailable();
        return value;
    }

    /// @dev Sources that are stale or invalid block opens; a market pause on
    /// stale data is part of the trading halt design.
    function _priceSourceFresh(uint256 marketId) internal view returns (bool) {
        PriceSource memory source = priceSources[marketId];
        if (source.kind == PRICE_SOURCE_METRIC) {
            return source.metricId != bytes32(0) && oracle.isFresh(source.metricId);
        }
        (, bool valid) = indexOracle.indexValue(marketId);
        return valid;
    }

    /// @dev Index price for liquidations and closes. An unusable index falls
    /// back to the mark price so positions can still be wound down.
    function _indexPriceSafe(uint256 marketId) internal view returns (uint256 price, bool valid) {
        PriceSource memory source = priceSources[marketId];
        if (source.kind == PRICE_SOURCE_METRIC) {
            if (source.metricId == bytes32(0) || !oracle.isFresh(source.metricId)) return (0, false);
            try oracle.getTWAP(source.metricId) returns (uint256 value) {
                return (value, true);
            } catch {
                return (0, false);
            }
        }
        return indexOracle.indexValue(marketId);
    }
}
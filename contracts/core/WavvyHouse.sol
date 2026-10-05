// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { FundingLib } from "../lib/FundingLib.sol";
import { WavvyMath } from "../lib/WavvyMath.sol";
import { IPosition } from "../interfaces/IPosition.sol";
import { IRiskManager } from "../interfaces/IRiskManager.sol";
import { IWavvyAMM } from "../interfaces/IWavvyAMM.sol";
import { IWavvyCreatorRewards } from "../interfaces/IWavvyCreatorRewards.sol";
import { IWavvyCurator } from "../interfaces/IWavvyCurator.sol";
import { IWavvyFactory } from "../interfaces/IWavvyFactory.sol";
import { IWavvyHouse } from "../interfaces/IWavvyHouse.sol";
import { IWavvyIndexOracle } from "../interfaces/IWavvyIndexOracle.sol";
import { IWavvyInsurance } from "../interfaces/IWavvyInsurance.sol";
import { IWavvyOracle } from "../interfaces/IWavvyOracle.sol";
import { IWavvyVault } from "../interfaces/IWavvyVault.sol";
import { LIQUIDATION_TARGET_BUFFER, WAD } from "../utils/Constants.sol";

/// @notice Composes the vault, the vAMM, the position ledger, the creator
/// escrow, and the curator registry into open, close, and liquidation flows.
///
/// Position ownership always resolves through the position token's current
/// holder, so a transferred token moves the whole position, margin included.
/// Margin lives in the position contract's vault account; a position has no
/// claim on its opener address after opening.
///
/// PnL settles against the treasury account with the insurance fund as the
/// backstop, the vault moves value between internal accounts only.
contract WavvyHouse is AccessControl, ReentrancyGuard, IWavvyHouse {
    bytes32 public constant MARKET_ADMIN_ROLE = keccak256("MARKET_ADMIN_ROLE");

    uint8 internal constant PRICE_SOURCE_METRIC = 0;
    uint8 internal constant PRICE_SOURCE_INDEX = 1;

    struct PriceSource {
        uint8 kind;
        bytes32 metricId;
    }

    IWavvyVault public immutable vault;
    IWavvyAMM public immutable amm;
    IWavvyOracle public immutable oracle;
    IWavvyIndexOracle public immutable indexOracle;

    IPosition public position;
    IRiskManager public risk;
    IWavvyInsurance public insurance;
    IWavvyFactory public factory;
    IWavvyCreatorRewards public creatorRewards;
    IWavvyCurator public curator;

    address public treasury;
    mapping(uint256 => PriceSource) public priceSources;

    error MarketPaused();
    error CircuitBreakerActive();
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
    error InvalidCopyCall();
    error SettlementMismatch();
    error SystemNotWired();
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
        uint256 payout,
        uint256 liquidatorPaid
    );
    event FundingSettled(uint256 indexed tokenId, int256 fundingCost);
    event BadDebt(uint256 indexed tokenId, uint256 deficit, uint256 covered);
    event FeeSplit(uint256 indexed marketId, uint256 protocolShare, uint256 creatorShare);
    event CopyFeeSettled(uint256 indexed callId, uint256 tokenId, uint256 curatorShare, uint256 protocolShare);
    event TreasuryUpdated(address indexed treasury);
    event SystemWired(address position, address risk, address insurance, address factory, address creatorRewards, address curator);
    event PriceSourceSet(uint256 indexed marketId, uint8 kind, bytes32 metricId);

    constructor(
        IWavvyVault vault_,
        IWavvyAMM amm_,
        IWavvyOracle oracle_,
        IWavvyIndexOracle indexOracle_,
        address treasury_,
        address admin
    ) {
        vault = vault_;
        amm = amm_;
        oracle = oracle_;
        indexOracle = indexOracle_;
        treasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Wire the contracts that are deployed after the house. Admin
    /// only; the admin role moves to the timelock at handover.
    function setSystem(
        address position_,
        address risk_,
        address insurance_,
        address factory_,
        address creatorRewards_,
        address curator_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        position = IPosition(position_);
        risk = IRiskManager(risk_);
        insurance = IWavvyInsurance(insurance_);
        factory = IWavvyFactory(factory_);
        creatorRewards = IWavvyCreatorRewards(creatorRewards_);
        curator = IWavvyCurator(curator_);
        emit SystemWired(position_, risk_, insurance_, factory_, creatorRewards_, curator_);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAmount();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @notice Point a market at its price source: a metric TWAP in the metric
    /// oracle, or the index oracle for basket markets. The factory calls this
    /// at market creation.
    function setMarketPriceSource(uint256 marketId, uint8 kind, bytes32 metricId)
        external
        onlyRole(MARKET_ADMIN_ROLE)
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
        _requireWired();
        if (!amm.marketExists(marketId)) revert MarketUnavailable();
        if (risk.isMarketPaused(marketId)) revert MarketPaused();
        if (risk.circuitBreakerTripped(marketId)) revert CircuitBreakerActive();
        if (!_priceSourceFresh(marketId)) revert MarketUnavailable();
        if (margin == 0 || margin < risk.minMargin(marketId)) revert InsufficientMargin();
        if (leverage < WAD) revert LeverageTooLow();
        if (leverage > risk.maxLeverage(marketId)) revert LeverageTooHigh();

        uint256 indexPrice = _indexPrice(marketId);
        uint256 mark = amm.markPrice(marketId);
        if (WavvyMath.deviationBps(mark, indexPrice) > risk.markDeviationPauseBps(marketId)) {
            revert MarkDeviationTooHigh();
        }

        // A copy must mirror the call: same market and side, and the call must
        // still be open. Otherwise copy fees would leak to unrelated curators.
        if (callId != 0) {
            (address callCurator, uint256 callMarketId, bool callIsLong,,, bool callActive) = curator.callInfo(callId);
            if (callCurator == address(0) || !callActive || callMarketId != marketId || callIsLong != isLong) {
                revert InvalidCopyCall();
            }
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
        _chargeOpenFees(msg.sender, marketId, fee);

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

        if (callId != 0) curator.recordCopy(callId, tokenId);

        emit PositionOpened(tokenId, marketId, msg.sender, isLong, size, entryPrice, margin, fee, callId);
    }

    /// @inheritdoc IWavvyHouse
    function closePosition(uint256 tokenId, uint256 closeSize) external nonReentrant returns (uint256 payout) {
        _requireWired();
        if (!position.exists(tokenId)) revert PositionNotFound();
        address holder = position.ownerOf(tokenId);
        if (msg.sender != holder) revert NotNFTOwner();

        IPosition.PositionData memory p = position.getPosition(tokenId);
        if (closeSize == 0 || closeSize > p.size) revert InvalidCloseSize();

        (uint256 effectiveIndex, int256 growth) = _closeContext(p.marketId);
        CloseResult memory r = _executeClose(p, closeSize, growth, effectiveIndex, risk.tradingFeeBps(p.marketId), 0);
        uint256 copyFee = _copyFeeFor(p, r.pnl, r.fundingCost);

        if (closeSize == p.size) {
            position.updatePosition(tokenId, 0, 0, growth);
            (payout,) = _settle(tokenId, holder, p.marketId, r.marginOut, r.pnl, r.fundingCost, r.fee + copyFee, 0, address(0), true);
            position.burnPosition(tokenId);
        } else {
            // Keep the old funding checkpoint: the remaining size still owes
            // the funding accrued up to this close.
            position.updatePosition(tokenId, p.size - closeSize, p.margin - r.marginOut, p.lastFundingGrowth);
            (payout,) = _settle(tokenId, holder, p.marketId, r.marginOut, r.pnl, r.fundingCost, r.fee + copyFee, 0, address(0), false);
        }

        if (copyFee > 0) _distributeCopyFee(p.callId, p.marketId, copyFee);

        emit FundingSettled(tokenId, r.fundingCost);
        emit PositionClosed(tokenId, holder, closeSize, r.exitPrice, payout, r.fee + copyFee);
    }

    /// Liquidation equity is measured against the price that is worse for the
    /// position (the lower of mark and index for longs, the higher for
    /// shorts), so a mark pushed away from the index cannot hide bad debt. The
    /// post-trade mark-versus-index deviation is checked afterwards: a
    /// liquidation whose execution leaves the mark beyond the deviation band
    /// reverts, which blocks liquidations triggered by an extreme move.
    ///
    /// @inheritdoc IWavvyHouse
    function liquidate(uint256 tokenId) external nonReentrant returns (uint256 payout, uint256 closedSize) {
        _requireWired();
        if (!position.exists(tokenId)) revert PositionNotFound();
        address holder = position.ownerOf(tokenId);
        IPosition.PositionData memory p = position.getPosition(tokenId);

        LiquidationContext memory ctx = _liquidationContext(p.marketId, p.isLong);
        if (!_isLiquidatable(p, ctx.growth, ctx.mark, ctx.equityPrice)) revert LiquidationNotAllowed();

        int256 equity = _equity(p, ctx.growth, ctx.equityPrice);
        uint256 target = equity > 0 ? _targetSize(p, uint256(equity), ctx.mark) : 0;
        if (target == 0 || target >= p.size) {
            (uint256 fullPayout, uint256 fullClosed,) = _fullLiquidate(tokenId, holder, p, ctx);
            return (fullPayout, fullClosed);
        }

        closedSize = p.size - target;
        CloseResult memory r =
            _executeClose(p, closedSize, ctx.growth, ctx.effectiveIndex, 0, risk.liquidationPenaltyBps(p.marketId));

        // The closed slice realizes its loss against margin instead of paying
        // the holder: equity stays in the position while notional shrinks,
        // which is what restores the margin ratio.
        int256 marginAfterSigned = WavvyMath.subSigned(
            WavvyMath.addSigned(WavvyMath.signed(p.margin), WavvyMath.subSigned(r.pnl, r.fundingCost)),
            WavvyMath.signed(r.penalty)
        );
        if (marginAfterSigned < 0) revert PartialCloseNotViable();
        uint256 marginAfter = uint256(marginAfterSigned);

        // Keep the old funding checkpoint on the remainder.
        position.updatePosition(tokenId, target, marginAfter, p.lastFundingGrowth);
        uint256 liquidatorPaid = _settleSlice(p.marketId, p.margin, marginAfter, r.pnl, r.fundingCost, r.penalty);
        payout = 0;

        _requireBoundedDeviation(p.marketId, ctx.effectiveIndex, ctx.indexValid);

        emit FundingSettled(tokenId, r.fundingCost);
        emit Liquidated(tokenId, msg.sender, holder, closedSize, r.penalty, payout, liquidatorPaid);

        // Escalate when the reduced position is still unhealthy.
        IPosition.PositionData memory afterData = position.getPosition(tokenId);
        LiquidationContext memory afterCtx = _liquidationContext(p.marketId, p.isLong);
        if (_isLiquidatable(afterData, afterCtx.growth, afterCtx.mark, afterCtx.equityPrice)) {
            (uint256 payoutRest, uint256 closedRest,) = _fullLiquidate(tokenId, holder, afterData, afterCtx);
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
        // FundingLib.payment returns the long-side cost: positive growth means
        // longs pay. Shorts take the opposite sign.
        int256 fundingPayment = FundingLib.payment(closedSize, growth, p.lastFundingGrowth);
        r.fundingCost = p.isLong ? fundingPayment : WavvyMath.subSigned(0, fundingPayment);
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
        LiquidationContext memory ctx
    ) internal returns (uint256 payout, uint256 closedSize, uint256 liquidatorPaid) {
        closedSize = p.size;
        CloseResult memory r =
            _executeClose(p, closedSize, ctx.growth, ctx.effectiveIndex, 0, risk.liquidationPenaltyBps(p.marketId));

        position.updatePosition(tokenId, 0, 0, ctx.growth);
        (payout, liquidatorPaid) =
            _settle(tokenId, holder, p.marketId, p.margin, r.pnl, r.fundingCost, 0, r.penalty, msg.sender, true);
        position.burnPosition(tokenId);

        _requireBoundedDeviation(p.marketId, ctx.effectiveIndex, ctx.indexValid);

        emit FundingSettled(tokenId, r.fundingCost);
        emit Liquidated(tokenId, msg.sender, holder, closedSize, r.penalty, payout, liquidatorPaid);
    }

    /// @dev Funding checkpoint and index price for closes. A stale or missing
    /// index freezes funding and falls back to the mark, so a position can
    /// always be wound down even while the oracle is out.
    function _closeContext(uint256 marketId) internal returns (uint256 effectiveIndex, int256 growth) {
        (uint256 indexPrice, bool indexValid) = _indexPriceSafe(marketId);
        if (indexValid) {
            return (indexPrice, amm.accrueFunding(marketId, indexPrice));
        }
        return (amm.markPrice(marketId), amm.fundingGrowth(marketId));
    }

    struct LiquidationContext {
        uint256 effectiveIndex;
        int256 growth;
        uint256 mark;
        uint256 equityPrice;
        bool indexValid;
    }

    /// @dev Funding checkpoint, mark, and the price used for liquidation
    /// equity. A stale or missing index falls back to the mark price so
    /// positions can still be wound down.
    function _liquidationContext(uint256 marketId, bool isLong)
        internal
        returns (LiquidationContext memory ctx)
    {
        (uint256 indexPrice, bool indexValid) = _indexPriceSafe(marketId);
        ctx.mark = amm.markPrice(marketId);
        ctx.indexValid = indexValid;
        if (indexValid) {
            ctx.effectiveIndex = indexPrice;
            ctx.growth = amm.accrueFunding(marketId, indexPrice);
        } else {
            ctx.effectiveIndex = ctx.mark;
            ctx.growth = amm.fundingGrowth(marketId);
        }
        ctx.equityPrice = ctx.mark;
        if (indexValid) {
            ctx.equityPrice = isLong
                ? WavvyMath.min(ctx.mark, indexPrice)
                : WavvyMath.max(ctx.mark, indexPrice);
        }
    }

    /// @dev Reverts the liquidation when executing it left the mark beyond the
    /// configured deviation band. The revert rolls the whole liquidation back,
    /// so a manipulated mark cannot force a liquidation through.
    function _requireBoundedDeviation(uint256 marketId, uint256 indexPrice, bool indexValid) internal view {
        if (!indexValid) return;
        uint256 mark = amm.markPrice(marketId);
        if (WavvyMath.deviationBps(mark, indexPrice) > risk.markDeviationPauseBps(marketId)) {
            revert MarkDeviationTooHigh();
        }
    }

    /// @dev Split the opening fee between the protocol treasury and the
    /// market's creators. The creator share is escrowed per creator id, split
    /// equally for index markets.
    function _chargeOpenFees(address user, uint256 marketId, uint256 fee) internal {
        if (fee == 0) return;
        uint256 creatorShare = WavvyMath.mulBps(fee, risk.creatorShareBps(marketId));
        uint256 protocolShare = fee - creatorShare;

        if (protocolShare > 0) vault.transfer(user, treasury, protocolShare);

        if (creatorShare > 0) {
            bytes32[] memory creators = factory.creatorIdsOf(marketId);
            uint256 count = creators.length;
            if (count == 0) {
                vault.transfer(user, treasury, creatorShare);
                emit FeeSplit(marketId, fee, 0);
                return;
            }
            uint256 per = creatorShare / count;
            for (uint256 i; i < count; ++i) {
                uint256 amount = i == count - 1 ? creatorShare - per * (count - 1) : per;
                if (amount == 0) continue;
                vault.transfer(user, address(creatorRewards), amount);
                creatorRewards.accrue(creators[i], amount);
            }
            emit FeeSplit(marketId, protocolShare, creatorShare);
        } else {
            emit FeeSplit(marketId, fee, 0);
        }
    }

    /// @dev Copy fee on a profitable close of an attributed position. Zero
    /// when the position mirrors no call or the copier made no profit.
    function _copyFeeFor(IPosition.PositionData memory p, int256 pnl, int256 fundingCost)
        internal
        view
        returns (uint256)
    {
        if (p.callId == 0) return 0;
        int256 profit = WavvyMath.subSigned(pnl, fundingCost);
        if (profit <= 0) return 0;
        return WavvyMath.mulBps(uint256(profit), risk.copyFeeBps(p.marketId));
    }

    /// @dev Move the curator share of a copy fee from the treasury into the
    /// curator contract's vault account and credit it. The protocol share
    /// stays in the treasury.
    function _distributeCopyFee(uint256 callId, uint256 marketId, uint256 copyFee) internal {
        uint256 curatorShare = WavvyMath.mulBps(copyFee, risk.curatorShareBps(marketId));
        if (curatorShare > 0) {
            vault.transfer(treasury, address(curator), curatorShare);
            curator.creditCopyFee(callId, curatorShare);
        }
        emit CopyFeeSettled(callId, 0, curatorShare, copyFee - curatorShare);
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
    ) internal returns (uint256 liquidatorPaid) {
        int256 net = WavvyMath.subSigned(pnl, fundingCost);
        if (net < 0) {
            vault.transfer(address(position), treasury, WavvyMath.absSigned(net));
        } else if (net > 0) {
            _ensureTreasury(uint256(net));
            vault.transfer(treasury, address(position), uint256(net));
        }
        if (penalty > 0) {
            vault.transfer(address(position), treasury, penalty);
            liquidatorPaid = _payLiquidationShares(marketId, msg.sender, penalty);
        }
        uint256 expected = uint256(
            WavvyMath.subSigned(WavvyMath.addSigned(WavvyMath.signed(marginBefore), net), WavvyMath.signed(penalty))
        );
        if (expected != marginAfter) revert SettlementMismatch();
    }

    function _payLiquidationShares(uint256 marketId, address liquidator, uint256 penalty)
        internal
        returns (uint256 loot)
    {
        loot = WavvyMath.mulBps(penalty, risk.liquidatorShareBps(marketId));
        uint256 insuranceShare = penalty - loot;
        if (loot > 0) vault.transfer(treasury, liquidator, loot);
        if (insuranceShare > 0) vault.transfer(treasury, address(insurance), insuranceShare);
    }

    /// @dev Pays the liquidator on the bad-debt path. The insurance fund is
    /// the first source, the treasury the second, so the account that spent
    /// gas still receives a share when a position blows through its margin.
    function _payBadDebtLiquidator(uint256 marketId, uint256 penalty, address liquidator)
        internal
        returns (uint256 paid)
    {
        if (penalty == 0 || liquidator == address(0)) return 0;
        uint256 loot = WavvyMath.mulBps(penalty, risk.liquidatorShareBps(marketId));
        if (loot == 0) return 0;
        paid = insurance.coverBadDebt(loot);
        uint256 shortfall = loot - paid;
        if (shortfall > 0) {
            uint256 fromTreasury = WavvyMath.min(shortfall, vault.balanceOf(treasury));
            if (fromTreasury > 0) {
                vault.transfer(treasury, address(this), fromTreasury);
                paid += fromTreasury;
            }
        }
        if (paid > 0) vault.transfer(address(this), liquidator, paid);
    }

    /// @dev Moves margin, PnL, funding, fees, and penalties between the
    /// position account, the holder, the treasury, the liquidator, and the
    /// insurance fund. Returns the payout sent to the holder and the amount
    /// paid to the liquidator. Zero-value internal transfers are skipped so a
    /// break-even close cannot revert on a zero transfer.
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
    ) internal returns (uint256 payout, uint256 liquidatorPaid) {
        int256 net =
            WavvyMath.subSigned(WavvyMath.subSigned(pnl, fundingCost), WavvyMath.signed(fee + penalty));
        int256 payoutSigned = WavvyMath.addSigned(WavvyMath.signed(marginIn), net);

        if (payoutSigned < 0) {
            if (!allowBadDebt) revert PartialCloseNotViable();
            if (marginIn > 0) vault.transfer(address(position), treasury, marginIn);
            uint256 deficit = WavvyMath.absSigned(payoutSigned);
            uint256 covered = insurance.coverBadDebt(deficit);
            if (covered > 0) vault.transfer(address(this), treasury, covered);
            liquidatorPaid = _payBadDebtLiquidator(marketId, penalty, liquidator);
            emit BadDebt(tokenId, deficit, covered);
            return (0, liquidatorPaid);
        }

        uint256 payoutOut = uint256(payoutSigned);
        if (net > 0) {
            _ensureTreasury(uint256(net) + penalty);
            vault.transfer(treasury, address(position), uint256(net));
        } else if (net < 0) {
            vault.transfer(address(position), treasury, WavvyMath.absSigned(net));
        }
        if (payoutOut > 0) vault.transfer(address(position), holder, payoutOut);

        if (penalty > 0 && liquidator != address(0)) {
            liquidatorPaid = _payLiquidationShares(marketId, liquidator, penalty);
        }

        return (payoutOut, liquidatorPaid);
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

    function _equity(IPosition.PositionData memory p, int256 growth, uint256 price)
        internal
        pure
        returns (int256)
    {
        int256 pnl = _pnl(p.isLong, p.size, p.entryPrice, price);
        int256 fundingPayment = FundingLib.payment(p.size, growth, p.lastFundingGrowth);
        int256 fundingCost = p.isLong ? fundingPayment : WavvyMath.subSigned(0, fundingPayment);
        return WavvyMath.subSigned(WavvyMath.addSigned(WavvyMath.signed(p.margin), pnl), fundingCost);
    }

    function _isLiquidatable(IPosition.PositionData memory p, int256 growth, uint256 mark, uint256 equityPrice)
        internal
        view
        returns (bool)
    {
        int256 equity = _equity(p, growth, equityPrice);
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

    function _requireWired() internal view {
        if (
            address(position) == address(0) || address(risk) == address(0) || address(insurance) == address(0)
                || address(factory) == address(0) || address(creatorRewards) == address(0)
                || address(curator) == address(0)
        ) {
            revert SystemNotWired();
        }
    }
}
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { WavvyHouse } from "../../contracts/core/WavvyHouse.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { WavvyAMM } from "../../contracts/core/WavvyAMM.sol";
import { WavvyPosition } from "../../contracts/core/WavvyPosition.sol";
import { WavvyInsurance } from "../../contracts/core/WavvyInsurance.sol";
import { WavvyFactory } from "../../contracts/core/WavvyFactory.sol";
import { WavvyCreatorRewards } from "../../contracts/core/WavvyCreatorRewards.sol";
import { WavvyCurator } from "../../contracts/core/WavvyCurator.sol";
import { FundingLib } from "../../contracts/lib/FundingLib.sol";
import { IPosition } from "../../contracts/interfaces/IPosition.sol";
import { MockIndexOracle, MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { MockERC20, MockRiskManager } from "./mocks/Mocks.sol";

contract WavvyHouseTest is Test {
    MockERC20 internal usdc;
    WavvyVault internal vault;
    WavvyAMM internal amm;
    WavvyPosition internal position;
    MockOracle internal oracle;
    MockIndexOracle internal indexOracle;
    MockRiskManager internal risk;
    WavvyInsurance internal insurance;
    WavvyFactory internal factory;
    WavvyCreatorRewards internal creatorRewards;
    WavvyCurator internal curator;
    WavvyHouse internal house;

    address internal admin = address(0xA11CE);
    address internal treasury = address(0x7E45);
    address internal grantsPool = address(0x6EA27);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal whale = address(0x5EA1);
    address internal big = address(0xB19);
    address internal liquidator = address(0x11D);
    address internal curatorUser = address(0xC0FFEE);
    address internal stranger = address(0xDEAD);

    bytes32 internal constant METRIC = keccak256("tiktok:creator:followers");
    bytes32 internal constant CREATOR = keccak256("tiktok:creator-a");
    bytes32 internal constant CREATOR_B = keccak256("tiktok:creator-b");
    uint256 internal constant MARKET = 1;
    uint256 internal constant MARKET_INDEX = 2;
    uint256 internal constant INDEX_PRICE = 1000e18;
    uint256 internal constant DEPTH = 1000e18;
    uint256 internal constant MAX_LEVERAGE = 3e18;
    uint256 internal constant MIN_MARGIN = 10e18;
    uint256 internal constant FUNDING_K = 1e18;
    uint256 internal constant MAX_FUNDING_RATE = 1e15;
    uint256 internal constant CREATOR_SHARE_BPS = 3000;
    uint256 internal constant COPY_FEE_BPS = 500;
    uint256 internal constant CURATOR_SHARE_BPS = 5000;

    function setUp() public {
        vm.warp(1_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 18);
        vault = new WavvyVault(usdc, admin);
        risk = new MockRiskManager();
        amm = new WavvyAMM(risk, admin);
        position = new WavvyPosition(admin);
        oracle = new MockOracle();
        indexOracle = new MockIndexOracle();
        insurance = new WavvyInsurance(vault, admin);
        creatorRewards = new WavvyCreatorRewards(vault, grantsPool, admin);
        curator = new WavvyCurator(vault, admin);
        house = new WavvyHouse(vault, amm, oracle, indexOracle, treasury, admin);
        factory = new WavvyFactory(amm, house, admin);

        vm.startPrank(admin);
        risk.setConfig(MARKET, _config());
        oracle.set(METRIC, INDEX_PRICE, true);

        house.grantRole(house.MARKET_ADMIN_ROLE(), address(factory));
        factory.grantRole(factory.MARKET_ADMIN_ROLE(), admin);
        vault.grantRole(vault.HOUSE_ROLE(), address(house));
        amm.grantRole(amm.HOUSE_ROLE(), address(house));
        amm.grantRole(amm.MARKET_ADMIN_ROLE(), address(factory));
        position.grantRole(position.HOUSE_ROLE(), address(house));
        insurance.grantRole(insurance.HOUSE_ROLE(), address(house));
        creatorRewards.grantRole(creatorRewards.HOUSE_ROLE(), address(house));
        curator.grantRole(curator.HOUSE_ROLE(), address(house));
        vault.grantRole(vault.SYSTEM_ROLE(), address(curator));

        house.setSystem(
            address(position), address(risk), address(insurance), address(factory), address(creatorRewards), address(curator)
        );

        bytes32[] memory creators = new bytes32[](1);
        creators[0] = CREATOR;
        factory.createMarket(MARKET, 0, METRIC, creators, INDEX_PRICE, DEPTH);
        vm.stopPrank();

        _fund(alice, 10_000e18);
        _fund(bob, 10_000e18);
        _fund(whale, 100_000e18);
        _fund(big, 2_000_000e18);
        _fund(curatorUser, 10_000e18);
    }

    function _config() internal pure returns (MockRiskManager.Config memory) {
        return MockRiskManager.Config({
            paused: false,
            maxLeverage: MAX_LEVERAGE,
            minMargin: MIN_MARGIN,
            openInterestCap: 1_000_000e18,
            maintenanceMarginBps: 1000,
            liquidationPenaltyBps: 250,
            liquidatorShareBps: 6000,
            tradingFeeBps: 10,
            markDeviationPauseBps: 500,
            fundingCoefficient: FUNDING_K,
            maxFundingRatePerBlock: MAX_FUNDING_RATE,
            creatorShareBps: CREATOR_SHARE_BPS,
            copyFeeBps: COPY_FEE_BPS,
            curatorShareBps: CURATOR_SHARE_BPS
        });
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _fundTreasury(uint256 amount) internal {
        _fund(treasury, amount);
    }

    function _fundInsurance(uint256 amount) internal {
        usdc.mint(admin, amount);
        vm.startPrank(admin);
        usdc.approve(address(insurance), amount);
        insurance.fund(amount);
        vm.stopPrank();
    }

    function _open(address who, bool isLong, uint256 margin, uint256 leverage) internal returns (uint256 tokenId) {
        vm.prank(who);
        return house.openPosition(MARKET, isLong, margin, leverage, 0);
    }

    function _openWithCall(address who, bool isLong, uint256 margin, uint256 leverage, uint256 callId)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(who);
        return house.openPosition(MARKET, isLong, margin, leverage, callId);
    }

    function _sizeOf(uint256 tokenId) internal view returns (uint256) {
        return position.getPosition(tokenId).size;
    }

    function _assertBacking() internal view {
        assertEq(vault.totalBacking(), vault.totalBalances());
        assertEq(vault.balanceOf(address(position)), position.totalMargin());
    }

    function test_OpenRecordsPositionAndChargesFee() public {
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        IPosition.PositionData memory p = position.getPosition(tokenId);
        assertEq(p.marketId, MARKET);
        assertTrue(p.isLong);
        assertEq(p.margin, 100e18);
        assertApproxEqRel(p.size, 0.3e18, 0.01e18);
        assertGt(p.entryPrice, INDEX_PRICE);
        assertEq(p.lastFundingGrowth, amm.fundingGrowth(MARKET));
        assertEq(position.ownerOf(tokenId), alice);

        uint256 fee = vault.balanceOf(treasury) + vault.balanceOf(address(creatorRewards));
        assertApproxEqAbs(fee, 0.3e18, 0.001e18); // 10 bps of ~300 notional
        assertApproxEqAbs(vault.balanceOf(treasury), 0.21e18, 0.001e18); // protocol 70 percent
        assertApproxEqAbs(creatorRewards.balanceOfCreator(CREATOR), 0.09e18, 0.001e18); // creator 30 percent
        assertEq(vault.balanceOf(address(position)), 100e18);
        assertEq(vault.balanceOf(alice), 10_000e18 - 100e18 - fee);

        (uint256 oiLong,) = amm.openInterest(MARKET);
        assertEq(oiLong, p.size);
        _assertBacking();
    }

    function test_LeverageAndMarginGuards() public {
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.LeverageTooHigh.selector);
        house.openPosition(MARKET, true, 100e18, 4e18, 0);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.LeverageTooLow.selector);
        house.openPosition(MARKET, true, 100e18, 0.5e18, 0);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.InsufficientMargin.selector);
        house.openPosition(MARKET, true, 5e18, 3e18, 0);

        vm.prank(stranger);
        vm.expectRevert(WavvyHouse.InsufficientMargin.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, 0);
    }

    function test_BelowMaintenanceMarginBlocksOpen() public {
        vm.prank(admin);
        risk.setMaintenanceMarginBps(MARKET, 4000);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.BelowMaintenanceMargin.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, 0);
    }

    function test_PausedMarketBlocksOpenButNotClose() public {
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        vm.prank(admin);
        risk.setPaused(MARKET, true);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.MarketPaused.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, 0);

        uint256 size = _sizeOf(tokenId);
        vm.prank(alice);
        house.closePosition(tokenId, size);
        assertFalse(position.exists(tokenId));
    }

    function test_MarkDeviationBlocksOpen() public {
        oracle.set(METRIC, 1500e18, true);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.MarkDeviationTooHigh.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, 0);
    }

    function test_StaleSourceBlocksOpen() public {
        oracle.set(METRIC, INDEX_PRICE, false);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.MarketUnavailable.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, 0);
    }

    function test_ReserveDepletedOnOversizedLong() public {
        vm.prank(big);
        vm.expectRevert(WavvyAMM.ReserveDepleted.selector);
        house.openPosition(MARKET, true, 400_000e18, 3e18, 0);
    }

    function test_CloseOwnershipAndSizeGuards() public {
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        vm.prank(stranger);
        vm.expectRevert(WavvyHouse.NotNFTOwner.selector);
        house.closePosition(tokenId, 0.3e18);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.InvalidCloseSize.selector);
        house.closePosition(tokenId, 1e18);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.PositionNotFound.selector);
        house.closePosition(999, 0.1e18);
    }

    function test_PositionTransferMovesOwnership() public {
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        vm.prank(alice);
        position.transferFrom(alice, bob, tokenId);
        assertEq(position.ownerOf(tokenId), bob);

        // The old holder can no longer close it.
        uint256 size = _sizeOf(tokenId);
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.NotNFTOwner.selector);
        house.closePosition(tokenId, size);

        // The new holder closes and receives the payout.
        uint256 bobBefore = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 payout = house.closePosition(tokenId, size);
        assertEq(vault.balanceOf(bob), bobBefore + payout);
        assertFalse(position.exists(tokenId));
    }

    function test_WinningClosePaysOutAndBurns() public {
        _fundTreasury(20_000e18);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(bob, true, 2000e18, 3e18);

        uint256 aliceBefore = vault.balanceOf(alice);
        uint256 size = _sizeOf(tokenId);
        vm.prank(alice);
        uint256 payout = house.closePosition(tokenId, size);

        assertGt(payout, 100e18);
        assertEq(vault.balanceOf(alice), aliceBefore + payout);
        assertFalse(position.exists(tokenId));
        assertEq(position.totalMargin(), 2000e18);
        _assertBacking();
    }

    function test_PartialCloseKeepsPositionOpen() public {
        _fundTreasury(20_000e18);
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        uint256 size = _sizeOf(tokenId);
        uint256 half = size / 2;
        vm.prank(alice);
        house.closePosition(tokenId, half);

        IPosition.PositionData memory p = position.getPosition(tokenId);
        assertTrue(position.exists(tokenId));
        assertEq(p.size, size - half);
        assertEq(p.margin, 100e18 - (100e18 * half) / size);

        vm.prank(alice);
        house.closePosition(tokenId, p.size);
        assertFalse(position.exists(tokenId));
        _assertBacking();
    }

    function test_FundingAccruesAcrossBlocks() public {
        _fundTreasury(20_000e18);
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        int256 growth0 = amm.fundingGrowth(MARKET);
        uint256 mark0 = amm.markPrice(MARKET);
        assertGt(mark0, INDEX_PRICE);

        vm.roll(block.number + 100);

        uint256 size = _sizeOf(tokenId);
        int256 rate = FundingLib.ratePerBlock(mark0, INDEX_PRICE, FUNDING_K, MAX_FUNDING_RATE);
        int256 expectedGrowth = growth0 + rate * 100;
        int256 expectedCost = FundingLib.payment(size, expectedGrowth, growth0);
        assertGt(expectedCost, 0);

        vm.expectEmit(true, false, false, true, address(house));
        emit WavvyHouse.FundingSettled(tokenId, expectedCost);

        vm.prank(alice);
        house.closePosition(tokenId, size);
    }

    function test_LiquidateHealthyPositionReverts() public {
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        vm.prank(liquidator);
        vm.expectRevert(WavvyHouse.LiquidationNotAllowed.selector);
        house.liquidate(tokenId);
    }

    function test_LiquidateUnknownPositionReverts() public {
        vm.prank(liquidator);
        vm.expectRevert(WavvyHouse.PositionNotFound.selector);
        house.liquidate(999);
    }

    function test_PartialLiquidationRestoresHealth() public {
        _fundTreasury(20_000e18);
        _fundInsurance(20_000e18);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        uint256 sizeBefore = _sizeOf(tokenId);

        _open(whale, false, 48_000e18, 3e18);
        // The index follows the metric; align it so the liquidation runs
        // inside the deviation band.
        oracle.set(METRIC, amm.markPrice(MARKET), true);

        uint256 insuranceBefore = insurance.balance();
        vm.prank(liquidator);
        (uint256 payout, uint256 closedSize) = house.liquidate(tokenId);

        assertGt(closedSize, 0);
        assertTrue(position.exists(tokenId)); // partial, not full

        IPosition.PositionData memory p = position.getPosition(tokenId);
        assertLt(p.size, sizeBefore);
        assertLt(p.margin, 100e18); // margin absorbed the slice loss and penalty

        uint256 mark = amm.markPrice(MARKET);
        int256 pnl = int256(p.size) * (int256(mark) - int256(p.entryPrice)) / 1e18;
        uint256 maintenance = p.size * mark / 1e18 * 1000 / 10_000;
        assertGe(int256(p.margin) + pnl, int256(maintenance));

        assertGt(vault.balanceOf(liquidator), 0);
        assertGt(insurance.balance(), insuranceBefore);
        assertEq(payout, 0);
        _assertBacking();
    }

    function test_FullLiquidationWithBadDebtCoveredByInsurance() public {
        _fundTreasury(20_000e18);
        _fundInsurance(20_000e18);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(whale, false, 64_000e18, 3e18); // mark falls below 2/3 of entry
        oracle.set(METRIC, amm.markPrice(MARKET), true);

        uint256 insuranceBefore = insurance.balance();

        vm.expectEmit(true, false, false, false, address(house));
        emit WavvyHouse.BadDebt(tokenId, 0, 0);

        vm.prank(liquidator);
        (uint256 payout, uint256 closedSize) = house.liquidate(tokenId);

        assertEq(payout, 0);
        assertGt(closedSize, 0);
        assertFalse(position.exists(tokenId));
        assertLt(insurance.balance(), insuranceBefore);
        // The liquidator is paid even when the position blew through its margin.
        assertGt(vault.balanceOf(liquidator), 0);
        _assertBacking();
    }

    function test_WinningCloseRevertsWhenNoBuffer() public {
        vm.prank(admin);
        risk.setTradingFeeBps(MARKET, 0);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(bob, true, 2000e18, 3e18);

        uint256 size = _sizeOf(tokenId);
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.ProtocolBufferExhausted.selector);
        house.closePosition(tokenId, size);
    }

    function test_LosingCloseMovesValueToTreasury() public {
        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(whale, false, 3000e18, 3e18);

        uint256 treasuryBefore = vault.balanceOf(treasury);
        uint256 size = _sizeOf(tokenId);
        vm.prank(alice);
        uint256 payout = house.closePosition(tokenId, size);

        assertLt(payout, 100e18);
        assertGt(vault.balanceOf(treasury), treasuryBefore);
        _assertBacking();
    }

    function test_CopyCallRecordsAttributionAndSplitsFee() public {
        _fundTreasury(20_000e18);

        vm.prank(curatorUser);
        uint256 callId = curator.createCall(MARKET, true, 100e18);

        uint256 tokenId = _openWithCall(alice, true, 100e18, 3e18, callId);
        assertEq(curator.attributionOf(tokenId), callId);
        assertEq(curator.copiesOf(callId), 1);

        _open(bob, true, 2000e18, 3e18); // mark rises, the copy turns profitable

        uint256 copySize = _sizeOf(tokenId);
        vm.prank(alice);
        house.closePosition(tokenId, copySize);

        uint256 credited = curator.claimable(curatorUser);
        assertGt(credited, 0);

        uint256 before = vault.balanceOf(curatorUser);
        vm.prank(curatorUser);
        curator.claim();
        assertEq(vault.balanceOf(curatorUser), before + credited);
        assertEq(curator.claimable(curatorUser), 0);
        _assertBacking();
    }

    function test_CloseWithoutAttributionPaysNoCopyFee() public {
        _fundTreasury(20_000e18);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(bob, true, 2000e18, 3e18);

        uint256 size = _sizeOf(tokenId);
        vm.prank(alice);
        house.closePosition(tokenId, size);
        assertEq(curator.claimable(curatorUser), 0);
    }

    function test_IndexMarketSplitsCreatorFeesEqually() public {
        bytes32[] memory creators = new bytes32[](2);
        creators[0] = CREATOR;
        creators[1] = CREATOR_B;

        vm.startPrank(admin);
        risk.setConfig(MARKET_INDEX, _config());
        indexOracle.set(MARKET_INDEX, INDEX_PRICE, true);
        factory.createMarket(MARKET_INDEX, 1, keccak256("index:tiktok-top5"), creators, INDEX_PRICE, DEPTH);
        vm.stopPrank();

        vm.prank(alice);
        house.openPosition(MARKET_INDEX, true, 100e18, 3e18, 0);

        uint256 total = vault.balanceOf(address(creatorRewards));
        assertGt(total, 0);
        uint256 first = creatorRewards.balanceOfCreator(CREATOR);
        uint256 second = creatorRewards.balanceOfCreator(CREATOR_B);
        assertGt(first, 0);
        assertGt(second, 0);
        // Equal split, so the two shares are within rounding of each other.
        assertApproxEqAbs(first, second, 3e15);
        assertApproxEqAbs(first + second, total, 3e15);
    }

    function test_SystemNotWiredBlocksTrading() public {
        WavvyHouse freshHouse = new WavvyHouse(vault, amm, oracle, indexOracle, treasury, admin);
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.SystemNotWired.selector);
        freshHouse.openPosition(MARKET, true, 100e18, 3e18, 0);
    }

    function test_CuratorStakeLocksAndReleases() public {
        vm.prank(curatorUser);
        uint256 callId = curator.createCall(MARKET, true, 100e18);
        assertEq(vault.balanceOf(address(curator)), 100e18);

        vm.prank(curatorUser);
        curator.closeCall(callId);
        assertEq(vault.balanceOf(address(curator)), 0);
        assertEq(vault.balanceOf(curatorUser), 10_000e18);
    }

    function test_ShortReceivesFundingWhenMarkAboveIndex() public {
        _fundTreasury(20_000e18);
        _open(bob, true, 2000e18, 3e18); // pushes the mark above the index
        uint256 shortId = _open(alice, false, 100e18, 3e18);

        int256 growth0 = amm.fundingGrowth(MARKET);
        uint256 mark0 = amm.markPrice(MARKET);
        assertGt(mark0, INDEX_PRICE);

        vm.roll(block.number + 100);

        uint256 size = _sizeOf(shortId);
        int256 rate = FundingLib.ratePerBlock(mark0, INDEX_PRICE, FUNDING_K, MAX_FUNDING_RATE);
        int256 expectedCost = -FundingLib.payment(size, growth0 + rate * 100, growth0);
        assertLt(expectedCost, 0); // a short receives when the mark is above the index

        vm.expectEmit(true, false, false, true, address(house));
        emit WavvyHouse.FundingSettled(shortId, expectedCost);

        vm.prank(alice);
        house.closePosition(shortId, size);
    }

    function test_PartialCloseKeepsFundingOnRemainder() public {
        _fundTreasury(20_000e18);
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        int256 growth0 = amm.fundingGrowth(MARKET);
        uint256 mark0 = amm.markPrice(MARKET);
        vm.roll(block.number + 100);
        int256 rate = FundingLib.ratePerBlock(mark0, INDEX_PRICE, FUNDING_K, MAX_FUNDING_RATE);
        int256 growth1 = growth0 + rate * 100;

        uint256 size = _sizeOf(tokenId);
        uint256 tiny = size / 10_000;

        vm.prank(alice);
        house.closePosition(tokenId, tiny);

        // The remainder still owes the full accumulated funding: closing it
        // at the same block must charge the whole checkpoint delta.
        uint256 remaining = size - tiny;
        int256 expectedRemainingCost = FundingLib.payment(remaining, growth1, growth0);
        assertGt(expectedRemainingCost, 0);

        vm.expectEmit(true, false, false, true, address(house));
        emit WavvyHouse.FundingSettled(tokenId, expectedRemainingCost);

        vm.prank(alice);
        house.closePosition(tokenId, remaining);
    }

    function test_ClosePositionWorksWhenIndexStale() public {
        _fundTreasury(20_000e18);
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        oracle.set(METRIC, INDEX_PRICE, false);

        uint256 size = _sizeOf(tokenId);
        vm.prank(alice);
        house.closePosition(tokenId, size);
        assertFalse(position.exists(tokenId));
    }

    function test_CopyCallMustMatchMarketAndSide() public {
        bytes32[] memory creators = new bytes32[](1);
        creators[0] = CREATOR;
        vm.startPrank(admin);
        risk.setConfig(MARKET_INDEX, _config());
        factory.createMarket(MARKET_INDEX, 0, METRIC, creators, INDEX_PRICE, DEPTH);
        vm.stopPrank();

        vm.prank(curatorUser);
        uint256 callId = curator.createCall(MARKET, true, 100e18);

        // Wrong side.
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.InvalidCopyCall.selector);
        house.openPosition(MARKET, false, 100e18, 3e18, callId);

        // Wrong market.
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.InvalidCopyCall.selector);
        house.openPosition(MARKET_INDEX, true, 100e18, 3e18, callId);

        // Closed call.
        vm.prank(curatorUser);
        curator.closeCall(callId);
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.InvalidCopyCall.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, callId);
    }

    function test_LiquidationRevertsWhenMarkDeviatesBeyondBand() public {
        _fundTreasury(20_000e18);
        _fundInsurance(20_000e18);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(whale, false, 48_000e18, 3e18); // mark far below the index

        vm.prank(liquidator);
        vm.expectRevert(WavvyHouse.MarkDeviationTooHigh.selector);
        house.liquidate(tokenId);
    }

    function test_LiquidationUsesWorseOfMarkAndIndex() public {
        _fundTreasury(20_000e18);
        _fundInsurance(20_000e18);

        // The short is healthy at the mark but not against the index, which is
        // the worse price for a short.
        vm.prank(admin);
        risk.setMaintenanceMarginBps(MARKET, 3330);

        uint256 tokenId = _open(alice, false, 100e18, 3e18);
        // Index sits just above the mark: the worse price for the short.
        oracle.set(METRIC, 1004e18, true);

        vm.prank(liquidator);
        (uint256 payout, uint256 closedSize) = house.liquidate(tokenId);

        assertGt(closedSize, 0);
        assertGe(payout, 0);
        _assertBacking();
    }

    function test_SetMarketPriceSourceGuards() public {
        vm.startPrank(admin);
        house.grantRole(house.MARKET_ADMIN_ROLE(), admin);

        vm.expectRevert(WavvyHouse.InvalidPriceSource.selector);
        house.setMarketPriceSource(99, 2, METRIC);

        vm.expectRevert(WavvyHouse.InvalidPriceSource.selector);
        house.setMarketPriceSource(99, 0, bytes32(0));
        vm.stopPrank();
    }

    function test_PartialCloseUnderwaterSliceReverts() public {
        _fundTreasury(20_000e18);
        _fund(whale, 100_000e18);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(whale, false, 150_000e18, 3e18); // mark far below entry

        uint256 size = _sizeOf(tokenId);
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.PartialCloseNotViable.selector);
        house.closePosition(tokenId, size / 5);
    }
}

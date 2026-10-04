// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { WavvyHouse } from "../../contracts/core/WavvyHouse.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { WavvyAMM } from "../../contracts/core/WavvyAMM.sol";
import { FundingLib } from "../../contracts/lib/FundingLib.sol";
import { IPosition } from "../../contracts/interfaces/IPosition.sol";
import { MockERC20, MockIndexOracle, MockInsurance, MockOracle, MockPosition, MockRiskManager } from "./mocks/Mocks.sol";

contract WavvyHouseTest is Test {
    MockERC20 internal usdc;
    WavvyVault internal vault;
    WavvyAMM internal amm;
    MockPosition internal position;
    MockOracle internal oracle;
    MockIndexOracle internal indexOracle;
    MockRiskManager internal risk;
    MockInsurance internal insurance;
    WavvyHouse internal house;

    address internal admin = address(0xA11CE);
    address internal treasury = address(0x7E45);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal whale = address(0x5EA1);
    address internal big = address(0xB19);
    address internal liquidator = address(0x11D);
    address internal stranger = address(0xDEAD);

    bytes32 internal constant METRIC = keccak256("tiktok:creator:followers");
    uint256 internal constant MARKET = 1;
    uint256 internal constant INDEX_PRICE = 1000e18;
    uint256 internal constant DEPTH = 1000e18;
    uint256 internal constant MAX_LEVERAGE = 3e18;
    uint256 internal constant MIN_MARGIN = 10e18;
    uint256 internal constant FUNDING_K = 1e18;
    uint256 internal constant MAX_FUNDING_RATE = 1e15;

    function setUp() public {
        vm.warp(1_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 18);
        vault = new WavvyVault(usdc, admin);
        risk = new MockRiskManager();
        amm = new WavvyAMM(risk, admin);
        position = new MockPosition();
        oracle = new MockOracle();
        indexOracle = new MockIndexOracle();
        insurance = new MockInsurance(vault);
        house = new WavvyHouse(
            vault, amm, position, oracle, indexOracle, risk, insurance, treasury, admin
        );

        vm.startPrank(admin);
        risk.setConfig(
            MARKET,
            MockRiskManager.Config({
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
                maxFundingRatePerBlock: MAX_FUNDING_RATE
            })
        );
        oracle.set(METRIC, INDEX_PRICE, true);
        amm.grantRole(amm.MARKET_ADMIN_ROLE(), admin);
        amm.createMarket(MARKET, INDEX_PRICE, DEPTH);
        house.setMarketPriceSource(MARKET, 0, METRIC);
        vault.grantRole(vault.HOUSE_ROLE(), address(house));
        amm.grantRole(amm.HOUSE_ROLE(), address(house));
        vm.stopPrank();

        _fund(alice, 10_000e18);
        _fund(bob, 10_000e18);
        _fund(whale, 100_000e18);
        _fund(big, 2_000_000e18);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _open(address who, bool isLong, uint256 margin, uint256 leverage) internal returns (uint256 tokenId) {
        vm.prank(who);
        return house.openPosition(MARKET, isLong, margin, leverage, 0);
    }

    function _fundTreasury(uint256 amount) internal {
        _fund(treasury, amount);
    }

    function _fundInsurance(uint256 amount) internal {
        _fund(address(insurance), amount);
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
        assertApproxEqRel(p.size, 0.3e18, 0.01e18); // refined against price impact
        assertGt(p.entryPrice, INDEX_PRICE); // buy impact
        assertEq(p.lastFundingGrowth, amm.fundingGrowth(MARKET));

        uint256 expectedFee = 0.3e18; // 10 bps of ~300 notional
        assertApproxEqAbs(vault.balanceOf(treasury), expectedFee, 0.001e18);
        assertEq(vault.balanceOf(address(position)), 100e18);
        assertEq(vault.balanceOf(alice), 10_000e18 - 100e18 - vault.balanceOf(treasury));

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
        risk.setMaintenanceMarginBps(MARKET, 4000); // 40 percent is more than 1/3x

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

        // Closing stays available while paused.
        uint256 size = position.getPosition(tokenId).size;
        vm.prank(alice);
        house.closePosition(tokenId, size);
        assertFalse(position.exists(tokenId));
    }

    function test_MarkDeviationBlocksOpen() public {
        oracle.set(METRIC, 1500e18, true); // 50 percent above the mark

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
        house.closePosition(tokenId, 0.4e18);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.PositionNotFound.selector);
        house.closePosition(999, 0.1e18);
    }

    function test_WinningClosePaysOutAndBurns() public {
        _fundTreasury(20_000e18);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(bob, true, 2000e18, 3e18); // pushes the mark up

        uint256 aliceBefore = vault.balanceOf(alice);
        uint256 size = position.getPosition(tokenId).size;
        vm.prank(alice);
        uint256 payout = house.closePosition(tokenId, size);

        assertGt(payout, 100e18); // profit over margin
        assertEq(vault.balanceOf(alice), aliceBefore + payout);
        assertFalse(position.exists(tokenId));
        assertEq(position.totalMargin(), 2000e18);
        _assertBacking();
    }

    function test_PartialCloseKeepsPositionOpen() public {
        _fundTreasury(20_000e18);
        uint256 tokenId = _open(alice, true, 100e18, 3e18);

        uint256 size = position.getPosition(tokenId).size;
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

        uint256 size = position.getPosition(tokenId).size;
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
        uint256 sizeBefore = position.getPosition(tokenId).size;

        // Whale short pushes the mark down until the position is just underwater.
        _open(whale, false, 48_000e18, 3e18);

        uint256 insuranceBefore = vault.balanceOf(address(insurance));
        vm.prank(liquidator);
        (uint256 payout, uint256 closedSize) = house.liquidate(tokenId);

        assertGt(closedSize, 0);
        assertTrue(position.exists(tokenId)); // partial, not full

        IPosition.PositionData memory p = position.getPosition(tokenId);
        assertLt(p.size, sizeBefore);
        assertLt(p.margin, 100e18); // margin absorbed the slice loss and penalty

        // Health restored: equity covers maintenance.
        uint256 mark = amm.markPrice(MARKET);
        int256 pnl = int256(p.size) * (int256(mark) - int256(p.entryPrice)) / 1e18;
        uint256 maintenance = p.size * mark / 1e18 * 1000 / 10_000;
        assertGe(int256(p.margin) + pnl, int256(maintenance));

        assertGt(vault.balanceOf(liquidator), 0);
        assertGt(vault.balanceOf(address(insurance)), insuranceBefore);
        assertEq(payout, 0); // a partial liquidation keeps the equity in place
        _assertBacking();
    }

    function test_FullLiquidationWithBadDebtCoveredByInsurance() public {
        _fundTreasury(20_000e18);
        _fundInsurance(20_000e18);

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(whale, false, 64_000e18, 3e18); // mark falls below 2/3 of entry

        uint256 insuranceBefore = vault.balanceOf(address(insurance));

        vm.expectEmit(true, false, false, false, address(house));
        emit WavvyHouse.BadDebt(tokenId, 0, 0);

        vm.prank(liquidator);
        (uint256 payout, uint256 closedSize) = house.liquidate(tokenId);

        assertEq(payout, 0);
        assertGt(closedSize, 0);
        assertFalse(position.exists(tokenId));
        assertLt(vault.balanceOf(address(insurance)), insuranceBefore); // covered the deficit
        _assertBacking();
    }

    function test_WinningCloseRevertsWhenNoBuffer() public {
        vm.prank(admin);
        risk.setTradingFeeBps(MARKET, 0); // no fee revenue reaches the treasury

        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(bob, true, 2000e18, 3e18); // mark rises

        uint256 size = position.getPosition(tokenId).size;
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.ProtocolBufferExhausted.selector);
        house.closePosition(tokenId, size);
    }

    function test_LosingCloseMovesValueToTreasury() public {
        uint256 tokenId = _open(alice, true, 100e18, 3e18);
        _open(whale, false, 3000e18, 3e18); // mark falls

        uint256 treasuryBefore = vault.balanceOf(treasury);
        uint256 size = position.getPosition(tokenId).size;
        vm.prank(alice);
        uint256 payout = house.closePosition(tokenId, size);

        assertLt(payout, 100e18);
        assertGt(vault.balanceOf(treasury), treasuryBefore);
        _assertBacking();
    }
}
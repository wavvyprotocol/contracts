// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { WavvyAMM } from "../../contracts/core/WavvyAMM.sol";
import { MockRiskManager } from "./mocks/Mocks.sol";

contract WavvyAMMTest is Test {
    MockRiskManager internal risk;
    WavvyAMM internal amm;

    address internal admin = address(0xA11CE);
    address internal stranger = address(0xDEAD);

    uint256 internal constant MARKET = 7;
    uint256 internal constant P0 = 1000e18;
    uint256 internal constant DEPTH = 1000e18;

    function setUp() public {
        vm.warp(1_000_000);
        risk = new MockRiskManager();
        amm = new WavvyAMM(risk, admin);

        vm.startPrank(admin);
        risk.setConfig(
            MARKET,
            MockRiskManager.Config({
                paused: false,
                maxLeverage: 3e18,
                minMargin: 10e18,
                openInterestCap: 1_000_000e18,
                maintenanceMarginBps: 1000,
                liquidationPenaltyBps: 250,
                liquidatorShareBps: 6000,
                tradingFeeBps: 10,
                markDeviationPauseBps: 500,
                fundingCoefficient: 1e18,
                maxFundingRatePerBlock: 1e15,
                creatorShareBps: 3000,
                copyFeeBps: 500,
                curatorShareBps: 5000
            })
        );
        amm.grantRole(amm.MARKET_ADMIN_ROLE(), admin);
        amm.grantRole(amm.HOUSE_ROLE(), address(this));
        amm.createMarket(MARKET, P0, DEPTH);
        vm.stopPrank();
    }

    function test_CreateMarketGuards() public {
        vm.startPrank(admin);
        vm.expectRevert(WavvyAMM.MarketExists.selector);
        amm.createMarket(MARKET, P0, DEPTH);

        vm.expectRevert(WavvyAMM.InvalidMarketParams.selector);
        amm.createMarket(8, 0, DEPTH);
        vm.stopPrank();

        bytes32 marketAdminRole = amm.MARKET_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, marketAdminRole)
        );
        amm.createMarket(9, P0, DEPTH);
    }

    function test_MarkPriceMovesWithTrades() public {
        assertEq(amm.markPrice(MARKET), P0);

        uint256 previewLong = amm.previewTrade(MARKET, true, 6e18, true);
        uint256 entry = amm.openTrade(MARKET, true, 6e18, P0);
        assertEq(entry, previewLong);
        assertGt(entry, P0); // buying pushes the mark up
        uint256 markUp = amm.markPrice(MARKET);
        assertGt(markUp, P0);

        uint256 previewShort = amm.previewTrade(MARKET, false, 6e18, true);
        uint256 shortEntry = amm.openTrade(MARKET, false, 6e18, P0);
        assertEq(shortEntry, previewShort);
        assertLt(amm.markPrice(MARKET), markUp); // selling pushes it back down
    }

    function test_ConstantProductInvariant() public {
        WavvyAMM.Market memory before = amm.getMarket(MARKET);
        uint256 kBefore = before.baseReserve * before.quoteReserve;

        amm.openTrade(MARKET, true, 6e18, P0);
        amm.openTrade(MARKET, false, 9e18, P0);
        amm.closeTrade(MARKET, true, 3e18, P0);
        amm.closeTrade(MARKET, false, 4e18, P0);

        WavvyAMM.Market memory afterMarket = amm.getMarket(MARKET);
        uint256 kAfter = afterMarket.baseReserve * afterMarket.quoteReserve;
        assertApproxEqRel(kAfter, kBefore, 1e6); // one part in a million
    }

    function test_OpenInterestTrackingAndCap() public {
        amm.openTrade(MARKET, true, 6e18, P0);
        (uint256 longOi,) = amm.openInterest(MARKET);
        assertEq(longOi, 6e18);
        amm.closeTrade(MARKET, true, 2e18, P0);
        (longOi,) = amm.openInterest(MARKET);
        assertEq(longOi, 4e18);

        // Tighten the cap and check that further notional is rejected.
        vm.prank(admin);
        risk.setOpenInterestCap(MARKET, 10_000e18);
        amm.openTrade(MARKET, false, 1e18, P0);
        vm.expectRevert(WavvyAMM.OpenInterestCapExceeded.selector);
        amm.openTrade(MARKET, false, 500e18, P0);
    }

    function test_OpenInterestUnderflowGuarded() public {
        vm.expectRevert(WavvyAMM.OpenInterestUnderflow.selector);
        amm.closeTrade(MARKET, true, 1e18, P0);
    }

    function test_PausedMarketBlocksOpens() public {
        vm.prank(admin);
        risk.setPaused(MARKET, true);
        vm.expectRevert(WavvyAMM.MarketPaused.selector);
        amm.openTrade(MARKET, true, 1e18, P0);
    }

    function test_RoleGates() public {
        bytes32 houseRole = amm.HOUSE_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, houseRole
            )
        );
        vm.prank(stranger);
        amm.openTrade(MARKET, true, 1e18, P0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, houseRole
            )
        );
        vm.prank(stranger);
        amm.accrueFunding(MARKET, P0);
    }

    function test_UnknownMarketReverts() public {
        vm.expectRevert(WavvyAMM.UnknownMarket.selector);
        amm.markPrice(999);
        vm.expectRevert(WavvyAMM.UnknownMarket.selector);
        amm.openTrade(999, true, 1e18, P0);
    }
}
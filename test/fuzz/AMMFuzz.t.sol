// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { WavvyAMM } from "../../contracts/core/WavvyAMM.sol";
import { WavvyMath } from "../../contracts/lib/WavvyMath.sol";
import { MockRiskManager } from "../core/mocks/Mocks.sol";

contract AMMFuzzTest is Test {
    WavvyAMM internal amm;
    MockRiskManager internal risk;

    address internal admin = address(0xA11CE);

    uint256 internal constant MARKET = 11;
    uint256 internal constant DEPTH = 1000e18;
    uint256 internal constant PRICE = 1000e18;

    function setUp() public {
        risk = new MockRiskManager();
        amm = new WavvyAMM(risk, admin);

        vm.startPrank(admin);
        risk.setConfig(
            MARKET,
            MockRiskManager.Config({
                paused: false,
                maxLeverage: 3e18,
                minMargin: 10e18,
                openInterestCap: type(uint128).max,
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
        amm.createMarket(MARKET, PRICE, DEPTH);
        vm.stopPrank();
    }

    function testFuzz_ProductNeverGrows(bool buy, uint96 sizeSeed) public {
        WavvyAMM.Market memory before = amm.getMarket(MARKET);
        uint256 kBefore = before.baseReserve * before.quoteReserve;

        uint256 size = bound(uint256(sizeSeed), 1, before.baseReserve / 2);
        if (buy) {
            amm.openTrade(MARKET, true, size, PRICE);
        } else {
            amm.openTrade(MARKET, false, size, PRICE);
        }

        WavvyAMM.Market memory afterMarket = amm.getMarket(MARKET);
        uint256 kAfter = afterMarket.baseReserve * afterMarket.quoteReserve;
        assertLe(kAfter, kBefore);
        assertGt(afterMarket.baseReserve, 0);
        assertGt(afterMarket.quoteReserve, 0);
    }

    function testFuzz_MarkMovesWithTradeDirection(bool buy, uint96 sizeSeed) public {
        uint256 size = bound(uint256(sizeSeed), 1e12, 1e20);
        uint256 markBefore = amm.markPrice(MARKET);

        if (buy) {
            uint256 price = amm.openTrade(MARKET, true, size, PRICE);
            assertGe(price, markBefore);
            assertGe(amm.markPrice(MARKET), markBefore);
        } else {
            uint256 price = amm.openTrade(MARKET, false, size, PRICE);
            assertLe(price, markBefore);
            assertLe(amm.markPrice(MARKET), markBefore);
        }
    }

    function testFuzz_OpenInterestTracksTrades(uint96 longSeed, uint96 shortSeed) public {
        uint256 longSize = bound(uint256(longSeed), 1e12, 1e19);
        uint256 shortSize = bound(uint256(shortSeed), 1e12, 1e19);

        amm.openTrade(MARKET, true, longSize, PRICE);
        amm.openTrade(MARKET, false, shortSize, PRICE);

        (uint256 oiLong, uint256 oiShort) = amm.openInterest(MARKET);
        assertEq(oiLong, longSize);
        assertEq(oiShort, shortSize);

        amm.closeTrade(MARKET, true, longSize, PRICE);
        amm.closeTrade(MARKET, false, shortSize, PRICE);

        (oiLong, oiShort) = amm.openInterest(MARKET);
        assertEq(oiLong, 0);
        assertEq(oiShort, 0);
    }

    function testFuzz_RoundTripNeverPaysTheTrader(uint96 sizeSeed) public {
        uint256 size = bound(uint256(sizeSeed), 1e12, 1e19);

        WavvyAMM.Market memory before = amm.getMarket(MARKET);
        amm.openTrade(MARKET, true, size, PRICE);
        WavvyAMM.Market memory opened = amm.getMarket(MARKET);
        amm.closeTrade(MARKET, true, size, PRICE);
        WavvyAMM.Market memory closed = amm.getMarket(MARKET);

        uint256 paid = opened.quoteReserve - before.quoteReserve;
        uint256 returned = opened.quoteReserve - closed.quoteReserve;
        assertLe(returned, paid + 2);
    }

    function testFuzz_FeeNeverExceedsNotional(uint96 notionalSeed, uint16 bpsSeed) public pure {
        uint256 notional = bound(uint256(notionalSeed), 0, 1e30);
        uint256 bps = bound(uint256(bpsSeed), 0, 10_000);

        assertLe(WavvyMath.mulBps(notional, bps), notional);
    }
}
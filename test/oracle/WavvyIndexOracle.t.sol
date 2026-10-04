// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { WavvyOracle } from "../../contracts/oracle/WavvyOracle.sol";
import { WavvyIndexOracle } from "../../contracts/oracle/WavvyIndexOracle.sol";
import { INDEX_BASE, INDEX_FLOOR } from "../../contracts/utils/Constants.sol";

contract WavvyIndexOracleTest is Test {
    WavvyOracle internal oracle;
    WavvyIndexOracle internal indexOracle;

    address internal admin = address(0xA11CE);
    address internal creReporter = address(0xC0FFEE);
    address internal stranger = address(0xDEAD);

    bytes32 internal constant METRIC_A = keccak256("tiktok:creator-a:followers");
    bytes32 internal constant METRIC_B = keccak256("tiktok:creator-b:followers");

    uint64 internal constant HEARTBEAT = 3600;
    uint64 internal constant TWAP_WINDOW = 7200;
    uint64 internal constant MIN_WINDOW = 1800;
    uint16 internal constant MAX_DEVIATION_BPS = 500;
    uint16 internal constant CIRCUIT_BREAKER_BPS = 2000;

    uint64 internal constant START_TIME = 2_000_000;
    uint256 internal constant MARKET_ID = 1;

    function setUp() public {
        vm.warp(START_TIME);
        oracle = new WavvyOracle(admin);
        indexOracle = new WavvyIndexOracle(oracle, admin);

        vm.startPrank(admin);
        oracle.registerMetric(METRIC_A, HEARTBEAT, TWAP_WINDOW, MIN_WINDOW, MAX_DEVIATION_BPS, CIRCUIT_BREAKER_BPS);
        oracle.registerMetric(METRIC_B, HEARTBEAT, TWAP_WINDOW, MIN_WINDOW, MAX_DEVIATION_BPS, CIRCUIT_BREAKER_BPS);
        oracle.grantRole(oracle.CRE_REPORTER_ROLE(), creReporter);

        bytes32[] memory metricIds = new bytes32[](2);
        metricIds[0] = METRIC_A;
        metricIds[1] = METRIC_B;
        uint256[] memory baselines = new uint256[](2);
        baselines[0] = 100e18;
        baselines[1] = 200e18;
        indexOracle.registerIndexMarket(MARKET_ID, metricIds, baselines);
        vm.stopPrank();
    }

    function _post(bytes32 metricId, uint256 value, uint64 observedAt) internal {
        vm.prank(creReporter);
        oracle.onReport("", abi.encode(metricId, value, observedAt, uint8(0)));
    }

    function test_IndexIsEqualWeightedGrowth() public {
        // A: 110 / 100 - 1 = +10%. B: 190 / 200 - 1 = -5%. Average +2.5%.
        _post(METRIC_A, 110e18, START_TIME);
        _post(METRIC_B, 190e18, START_TIME);

        vm.warp(START_TIME + HEARTBEAT);
        (uint256 value, bool valid) = indexOracle.indexValue(MARKET_ID);

        assertTrue(valid);
        assertEq(value, 1025e18);
        assertEq(indexOracle.constituentCount(MARKET_ID), 2);
    }

    function test_FrozenConstituentIsExcluded() public {
        _post(METRIC_A, 110e18, START_TIME);
        _post(METRIC_B, 190e18, START_TIME);

        vm.prank(admin);
        indexOracle.setConstituentFrozen(MARKET_ID, 0, true);

        vm.warp(START_TIME + HEARTBEAT);
        (uint256 value, bool valid) = indexOracle.indexValue(MARKET_ID);

        assertTrue(valid);
        // Only B remains: 1000 * (1 - 0.05) = 950.
        assertEq(value, 950e18);
    }

    function test_StaleConstituentIsExcluded() public {
        _post(METRIC_A, 110e18, START_TIME);
        _post(METRIC_B, 190e18, START_TIME);

        // Refresh A so only B is past its heartbeat.
        vm.warp(START_TIME + HEARTBEAT);
        _post(METRIC_A, 110e18, START_TIME + HEARTBEAT);

        vm.warp(START_TIME + HEARTBEAT + 100);
        assertFalse(oracle.isFresh(METRIC_B));

        (uint256 value, bool valid) = indexOracle.indexValue(MARKET_ID);
        assertTrue(valid);
        // Only A remains: 1000 * 1.10 = 1100.
        assertEq(value, 1100e18);
    }

    function test_ConstituentWithoutHistoryIsSkipped() public {
        // B never reports: its TWAP cannot be computed.
        _post(METRIC_A, 110e18, START_TIME);

        vm.warp(START_TIME + HEARTBEAT);
        (uint256 value, bool valid) = indexOracle.indexValue(MARKET_ID);

        assertTrue(valid);
        assertEq(value, 1100e18);
    }

    function test_NoUsableConstituentReturnsInvalid() public {
        _post(METRIC_A, 110e18, START_TIME);
        _post(METRIC_B, 190e18, START_TIME);

        vm.warp(START_TIME + HEARTBEAT + 1);
        (uint256 value, bool valid) = indexOracle.indexValue(MARKET_ID);

        assertFalse(valid);
        assertEq(value, 0);
    }

    function test_RebalanceResetsGrowthWithFreshBaselines() public {
        _post(METRIC_A, 110e18, START_TIME);
        _post(METRIC_B, 190e18, START_TIME);
        vm.warp(START_TIME + HEARTBEAT);

        bytes32[] memory metricIds = new bytes32[](2);
        metricIds[0] = METRIC_A;
        metricIds[1] = METRIC_B;
        uint256[] memory baselines = new uint256[](2);
        baselines[0] = 110e18;
        baselines[1] = 190e18;

        vm.prank(admin);
        indexOracle.rebalance(MARKET_ID, metricIds, baselines);

        (uint256 value, bool valid) = indexOracle.indexValue(MARKET_ID);
        assertTrue(valid);
        assertEq(value, INDEX_BASE);
    }

    function test_IndexIsFlooredInExtremeDownside() public {
        bytes32[] memory metricIds = new bytes32[](1);
        metricIds[0] = METRIC_A;
        uint256[] memory baselines = new uint256[](1);
        baselines[0] = 100e18;
        vm.prank(admin);
        indexOracle.registerIndexMarket(2, metricIds, baselines);

        // 1 / 100 - 1 = -99%, raw value would be 10 points.
        _post(METRIC_A, 1e18, START_TIME);
        vm.warp(START_TIME + MIN_WINDOW);

        (uint256 value, bool valid) = indexOracle.indexValue(2);
        assertTrue(valid);
        assertEq(value, INDEX_FLOOR);
    }

    function test_UnknownMarketReturnsInvalid() public view {
        (uint256 value, bool valid) = indexOracle.indexValue(99);
        assertFalse(valid);
        assertEq(value, 0);
    }

    function test_RegistrationGuards() public {
        vm.startPrank(admin);

        bytes32[] memory one = new bytes32[](1);
        one[0] = METRIC_A;
        uint256[] memory none = new uint256[](0);

        vm.expectRevert(WavvyIndexOracle.LengthMismatch.selector);
        indexOracle.registerIndexMarket(3, one, none);

        uint256[] memory zeroBaseline = new uint256[](1);
        vm.expectRevert(WavvyIndexOracle.ZeroBaseline.selector);
        indexOracle.registerIndexMarket(3, one, zeroBaseline);

        bytes32[] memory empty = new bytes32[](0);
        uint256[] memory emptyValues = new uint256[](0);
        vm.expectRevert(WavvyIndexOracle.EmptyConstituents.selector);
        indexOracle.registerIndexMarket(3, empty, emptyValues);

        vm.expectRevert(WavvyIndexOracle.DuplicateIndexMarket.selector);
        indexOracle.registerIndexMarket(MARKET_ID, one, zeroBaseline);

        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0)
            )
        );
        indexOracle.registerIndexMarket(3, one, zeroBaseline);
    }
}
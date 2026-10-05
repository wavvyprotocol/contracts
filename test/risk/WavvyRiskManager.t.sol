// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { WavvyRiskManager } from "../../contracts/risk/WavvyRiskManager.sol";
import { WavvyTimelock } from "../../contracts/governance/WavvyTimelock.sol";

contract WavvyRiskManagerTest is Test {
    WavvyRiskManager internal risk;

    address internal admin = address(0xA11CE);
    address internal pauser = address(0x9A05E);
    address internal stranger = address(0xDEAD);

    function _singleParams() internal pure returns (WavvyRiskManager.RiskParams memory) {
        return WavvyRiskManager.RiskParams({
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
        });
    }

    function _indexParams() internal pure returns (WavvyRiskManager.RiskParams memory params) {
        params = _singleParams();
        params.maxLeverage = 5e18;
    }

    function setUp() public {
        risk = new WavvyRiskManager(admin);
        bytes32 pauserRole = risk.PAUSER_ROLE();
        vm.prank(admin);
        risk.grantRole(pauserRole, pauser);
    }

    function _configure() internal {
        vm.startPrank(admin);
        risk.setTypeDefaults(risk.TYPE_SINGLE_NAME(), _singleParams());
        risk.setTypeDefaults(risk.TYPE_INDEX(), _indexParams());
        risk.configureMarket(1, risk.TYPE_SINGLE_NAME());
        risk.configureMarket(2, risk.TYPE_INDEX());
        vm.stopPrank();
    }

    function test_TypeDefaultsSeedMarkets() public {
        _configure();

        assertTrue(risk.marketConfigured(1));
        assertEq(risk.marketTypeOf(1), risk.TYPE_SINGLE_NAME());
        assertEq(risk.maxLeverage(1), 3e18);
        assertEq(risk.maxLeverage(2), 5e18); // index default
        assertEq(risk.minMargin(1), 10e18);
        assertEq(risk.openInterestCap(1), 1_000_000e18);
        assertEq(risk.maintenanceMarginBps(1), 1000);
        assertEq(risk.liquidationPenaltyBps(1), 250);
        assertEq(risk.liquidatorShareBps(1), 6000);
        assertEq(risk.tradingFeeBps(1), 10);
        assertEq(risk.markDeviationPauseBps(1), 500);
        assertEq(risk.fundingCoefficient(1), 1e18);
        assertEq(risk.maxFundingRatePerBlock(1), 1e15);
        assertEq(risk.creatorShareBps(1), 3000);
        assertEq(risk.copyFeeBps(1), 500);
        assertEq(risk.curatorShareBps(1), 5000);
    }

    function test_ConfigureGuards() public {
        uint8 singleType = risk.TYPE_SINGLE_NAME();
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(WavvyRiskManager.TypeDefaultsMissing.selector, singleType));
        risk.configureMarket(1, singleType);

        risk.setTypeDefaults(singleType, _singleParams());
        vm.expectRevert(abi.encodeWithSelector(WavvyRiskManager.InvalidMarketType.selector, uint8(9)));
        risk.configureMarket(1, 9);

        risk.configureMarket(1, singleType);
        vm.expectRevert(abi.encodeWithSelector(WavvyRiskManager.MarketAlreadyConfigured.selector, uint256(1)));
        risk.configureMarket(1, singleType);
        vm.stopPrank();
    }

    function test_UnconfiguredMarketGettersRevert() public {
        vm.expectRevert(abi.encodeWithSelector(WavvyRiskManager.MarketNotConfigured.selector, uint256(99)));
        risk.maxLeverage(99);
        vm.expectRevert(abi.encodeWithSelector(WavvyRiskManager.MarketNotConfigured.selector, uint256(99)));
        risk.paramsOf(99);

        // Pause and breaker reads are safe on unconfigured markets.
        assertFalse(risk.isMarketPaused(99));
        assertFalse(risk.circuitBreakerTripped(99));
    }

    function test_InvalidParamsRejected() public {
        uint8 singleType = risk.TYPE_SINGLE_NAME();
        vm.startPrank(admin);
        WavvyRiskManager.RiskParams memory p = _singleParams();

        p.maxLeverage = 0.5e18;
        vm.expectRevert(WavvyRiskManager.InvalidParams.selector);
        risk.setTypeDefaults(singleType, p);

        p = _singleParams();
        p.maintenanceMarginBps = 10_000;
        vm.expectRevert(WavvyRiskManager.InvalidParams.selector);
        risk.setTypeDefaults(singleType, p);

        p = _singleParams();
        p.fundingCoefficient = 0;
        vm.expectRevert(WavvyRiskManager.InvalidParams.selector);
        risk.setTypeDefaults(singleType, p);

        p = _singleParams();
        p.maxFundingRatePerBlock = 0;
        vm.expectRevert(WavvyRiskManager.InvalidParams.selector);
        risk.setTypeDefaults(singleType, p);

        p = _singleParams();
        p.markDeviationPauseBps = 0;
        vm.expectRevert(WavvyRiskManager.InvalidParams.selector);
        risk.setTypeDefaults(singleType, p);
        vm.stopPrank();
    }

    function test_GranularSettersUpdateAndValidate() public {
        _configure();

        vm.startPrank(admin);
        risk.setMaxLeverage(1, 2e18);
        assertEq(risk.maxLeverage(1), 2e18);

        risk.setOpenInterestCap(1, 500e18);
        assertEq(risk.openInterestCap(1), 500e18);

        risk.setFundingParams(1, 2e18, 5e14);
        assertEq(risk.fundingCoefficient(1), 2e18);
        assertEq(risk.maxFundingRatePerBlock(1), 5e14);

        risk.setFeeShares(1, 2000, 400, 6000);
        assertEq(risk.creatorShareBps(1), 2000);
        assertEq(risk.copyFeeBps(1), 400);
        assertEq(risk.curatorShareBps(1), 6000);

        risk.setLiquidationParams(1, 300, 5000);
        assertEq(risk.liquidationPenaltyBps(1), 300);
        assertEq(risk.liquidatorShareBps(1), 5000);

        risk.setTradingFeeBps(1, 15);
        assertEq(risk.tradingFeeBps(1), 15);

        risk.setMarkDeviationPauseBps(1, 700);
        assertEq(risk.markDeviationPauseBps(1), 700);

        risk.setMaintenanceMarginBps(1, 1500);
        assertEq(risk.maintenanceMarginBps(1), 1500);

        risk.setMinMargin(1, 25e18);
        assertEq(risk.minMargin(1), 25e18);

        // An invalid value reverts and leaves the stored value untouched.
        vm.expectRevert(WavvyRiskManager.InvalidParams.selector);
        risk.setMaxLeverage(1, 0.9e18);
        assertEq(risk.maxLeverage(1), 2e18);
        vm.stopPrank();
    }

    function test_SettersAreAdminOnly() public {
        _configure();
        bytes32 adminRole = risk.DEFAULT_ADMIN_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        risk.setMaxLeverage(1, 2e18);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        risk.unpauseMarket(1);

        // The pauser cannot change parameters or unpause.
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole)
        );
        risk.setOpenInterestCap(1, 1e18);
    }

    function test_PauseAndUnpauseRules() public {
        _configure();
        bytes32 adminRole = risk.DEFAULT_ADMIN_ROLE();

        vm.prank(pauser);
        risk.pauseMarket(1);
        assertTrue(risk.isMarketPaused(1));

        // The pauser cannot unpause; reopening goes through admin (timelock).
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole
            )
        );
        risk.unpauseMarket(1);

        vm.prank(admin);
        risk.unpauseMarket(1);
        assertFalse(risk.isMarketPaused(1));
    }

    function test_CircuitBreakerRules() public {
        _configure();
        bytes32 adminRole = risk.DEFAULT_ADMIN_ROLE();

        vm.prank(pauser);
        risk.tripCircuitBreaker(1);
        assertTrue(risk.circuitBreakerTripped(1));

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole
            )
        );
        risk.resetCircuitBreaker(1);

        vm.prank(admin);
        risk.resetCircuitBreaker(1);
        assertFalse(risk.circuitBreakerTripped(1));
    }

    function test_SetMarketParamsReplacesEverything() public {
        _configure();

        WavvyRiskManager.RiskParams memory p = _singleParams();
        p.maxLeverage = 1.5e18;
        p.tradingFeeBps = 5;

        vm.prank(admin);
        risk.setMarketParams(1, p);
        assertEq(risk.maxLeverage(1), 1.5e18);
        assertEq(risk.tradingFeeBps(1), 5);
    }

    function test_TypeDefaultsReadBack() public {
        _configure();
        WavvyRiskManager.RiskParams memory stored = risk.typeDefaultsOf(risk.TYPE_INDEX());
        assertEq(stored.maxLeverage, 5e18);

        vm.expectRevert(abi.encodeWithSelector(WavvyRiskManager.TypeDefaultsMissing.selector, uint8(9)));
        risk.typeDefaultsOf(9);
    }
}

/// @notice The timelock gates every parameter change. Direct admin writes stop
/// working after handover; scheduled calls apply only after the delay.
contract WavvyTimelockTest is Test {
    WavvyRiskManager internal risk;
    WavvyTimelock internal timelock;

    address internal admin = address(0xA11CE);
    address internal stranger = address(0xDEAD);

    uint256 internal constant DELAY = 3600;

    function _params() internal pure returns (WavvyRiskManager.RiskParams memory) {
        return WavvyRiskManager.RiskParams({
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
        });
    }

    function setUp() public {
        vm.warp(1_000_000);
        risk = new WavvyRiskManager(admin);

        vm.startPrank(admin);
        risk.setTypeDefaults(risk.TYPE_SINGLE_NAME(), _params());
        risk.configureMarket(1, risk.TYPE_SINGLE_NAME());

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution once ready
        timelock = new WavvyTimelock(DELAY, proposers, executors, admin);

        // Handover: the timelock holds the admin role, the deployer renounces.
        risk.grantRole(risk.DEFAULT_ADMIN_ROLE(), address(timelock));
        risk.renounceRole(risk.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();
    }

    function test_TimelockDelaysParameterChange() public {
        bytes memory data = abi.encodeCall(WavvyRiskManager.setMaxLeverage, (1, 2e18));
        bytes32 salt = keccak256("lower leverage");
        bytes32 adminRole = risk.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        timelock.schedule(address(risk), 0, data, bytes32(0), salt, DELAY);

        // Direct admin writes fail after handover.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole
            )
        );
        risk.setMaxLeverage(1, 2e18);

        // The scheduled call is not executable before the delay.
        vm.expectRevert();
        timelock.execute(address(risk), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY + 1);
        timelock.execute(address(risk), 0, data, bytes32(0), salt);
        assertEq(risk.maxLeverage(1), 2e18);
    }

    function test_ScheduleIsProposerOnly() public {
        bytes memory data = abi.encodeCall(WavvyRiskManager.setMaxLeverage, (1, 2e18));
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, proposerRole
            )
        );
        timelock.schedule(address(risk), 0, data, bytes32(0), keccak256("x"), DELAY);
    }

    function test_MinDelayExposed() public view {
        assertEq(timelock.getMinDelay(), DELAY);
    }
}
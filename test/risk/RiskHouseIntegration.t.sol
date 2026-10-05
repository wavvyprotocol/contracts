// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { WavvyAMM } from "../../contracts/core/WavvyAMM.sol";
import { WavvyCreatorRewards } from "../../contracts/core/WavvyCreatorRewards.sol";
import { WavvyCurator } from "../../contracts/core/WavvyCurator.sol";
import { WavvyFactory } from "../../contracts/core/WavvyFactory.sol";
import { WavvyHouse } from "../../contracts/core/WavvyHouse.sol";
import { WavvyInsurance } from "../../contracts/core/WavvyInsurance.sol";
import { WavvyPosition } from "../../contracts/core/WavvyPosition.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { WavvyRiskManager } from "../../contracts/risk/WavvyRiskManager.sol";
import { MockIndexOracle, MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { MockERC20 } from "../core/mocks/Mocks.sol";

contract RiskHouseIntegrationTest is Test {
    MockERC20 internal usdc;
    WavvyVault internal vault;
    WavvyRiskManager internal risk;
    WavvyAMM internal amm;
    WavvyPosition internal position;
    MockOracle internal oracle;
    MockIndexOracle internal indexOracle;
    WavvyInsurance internal insurance;
    WavvyFactory internal factory;
    WavvyCreatorRewards internal creatorRewards;
    WavvyCurator internal curator;
    WavvyHouse internal house;

    address internal admin = address(0xA11CE);
    address internal treasury = address(0x7E45);
    address internal grantsPool = address(0x6EA27);
    address internal alice = address(0xA1);

    bytes32 internal constant METRIC = keccak256("tiktok:creator:followers");
    bytes32 internal constant CREATOR = keccak256("tiktok:creator-a");
    uint256 internal constant MARKET = 1;
    uint256 internal constant PRICE = 1000e18;
    uint256 internal constant DEPTH = 1000e18;

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

        usdc = new MockERC20("USD Coin", "USDC", 18);
        vault = new WavvyVault(usdc, admin);
        risk = new WavvyRiskManager(admin);
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
        risk.setTypeDefaults(risk.TYPE_SINGLE_NAME(), _params());
        risk.configureMarket(MARKET, risk.TYPE_SINGLE_NAME());
        risk.grantRole(risk.PAUSER_ROLE(), admin);
        oracle.set(METRIC, PRICE, true);

        house.grantRole(house.MARKET_ADMIN_ROLE(), address(factory));
        factory.grantRole(factory.MARKET_ADMIN_ROLE(), admin);
        vault.grantRole(vault.HOUSE_ROLE(), address(house));
        amm.grantRole(amm.HOUSE_ROLE(), address(house));
        amm.grantRole(amm.MARKET_ADMIN_ROLE(), address(factory));
        position.grantRole(position.HOUSE_ROLE(), address(house));
        insurance.grantRole(insurance.HOUSE_ROLE(), address(house));
        creatorRewards.grantRole(creatorRewards.HOUSE_ROLE(), address(house));
        curator.grantRole(curator.HOUSE_ROLE(), address(house));

        house.setSystem(
            address(position), address(risk), address(insurance), address(factory), address(creatorRewards), address(curator)
        );

        bytes32[] memory creators = new bytes32[](1);
        creators[0] = CREATOR;
        factory.createMarket(MARKET, 0, METRIC, creators, PRICE, DEPTH);
        vm.stopPrank();

        usdc.mint(alice, 10_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e18);
        vault.deposit(10_000e18);
        vm.stopPrank();
    }

    function _open(uint256 leverage) internal returns (uint256 tokenId) {
        vm.prank(alice);
        return house.openPosition(MARKET, true, 100e18, leverage, 0);
    }

    function test_RiskManagerBlocksOverLeverageOpen() public {
        vm.prank(alice);
        vm.expectRevert(WavvyHouse.LeverageTooHigh.selector);
        house.openPosition(MARKET, true, 100e18, 4e18, 0);

        uint256 tokenId = _open(3e18);
        assertTrue(position.exists(tokenId));
    }

    function test_PausedMarketRejectsOpensAndAllowsCloses() public {
        uint256 tokenId = _open(3e18);

        vm.prank(admin);
        risk.pauseMarket(MARKET);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.MarketPaused.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, 0);

        uint256 size = position.getPosition(tokenId).size;
        vm.prank(alice);
        house.closePosition(tokenId, size);
        assertFalse(position.exists(tokenId));

        vm.prank(admin);
        risk.unpauseMarket(MARKET);
        uint256 reopened = _open(3e18);
        assertTrue(position.exists(reopened));
    }

    function test_CircuitBreakerBlocksOpensAndAllowsCloses() public {
        uint256 tokenId = _open(3e18);

        vm.prank(admin);
        risk.tripCircuitBreaker(MARKET);

        vm.prank(alice);
        vm.expectRevert(WavvyHouse.CircuitBreakerActive.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, 0);

        uint256 size = position.getPosition(tokenId).size;
        vm.prank(alice);
        house.closePosition(tokenId, size);
        assertFalse(position.exists(tokenId));

        vm.prank(admin);
        risk.resetCircuitBreaker(MARKET);
        uint256 reopened = _open(3e18);
        assertTrue(position.exists(reopened));
    }

    function test_OpenInterestCapComesFromRiskManager() public {
        vm.prank(admin);
        risk.setOpenInterestCap(MARKET, 200e18); // 300 notional would exceed it

        vm.prank(alice);
        vm.expectRevert(WavvyAMM.OpenInterestCapExceeded.selector);
        house.openPosition(MARKET, true, 100e18, 3e18, 0);
    }
}
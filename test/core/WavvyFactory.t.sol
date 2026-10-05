// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { WavvyAMM } from "../../contracts/core/WavvyAMM.sol";
import { WavvyFactory } from "../../contracts/core/WavvyFactory.sol";
import { WavvyHouse } from "../../contracts/core/WavvyHouse.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { MockIndexOracle, MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { MockERC20, MockRiskManager } from "./mocks/Mocks.sol";

contract WavvyFactoryTest is Test {
    MockERC20 internal usdc;
    WavvyVault internal vault;
    MockRiskManager internal risk;
    WavvyAMM internal amm;
    MockOracle internal oracle;
    MockIndexOracle internal indexOracle;
    WavvyHouse internal house;
    WavvyFactory internal factory;

    address internal admin = address(0xA11CE);
    address internal treasury = address(0x7E45);
    address internal stranger = address(0xDEAD);

    bytes32 internal constant METRIC = keccak256("youtube:creator-1:subscribers");
    bytes32 internal constant CREATOR_A = keccak256("youtube:creator-1");
    bytes32 internal constant CREATOR_B = keccak256("tiktok:creator-2");
    uint256 internal constant PRICE = 1000e18;
    uint256 internal constant DEPTH = 1000e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        vault = new WavvyVault(usdc, admin);
        risk = new MockRiskManager();
        amm = new WavvyAMM(risk, admin);
        oracle = new MockOracle();
        indexOracle = new MockIndexOracle();
        house = new WavvyHouse(vault, amm, oracle, indexOracle, treasury, admin);
        factory = new WavvyFactory(amm, house, admin);

        vm.startPrank(admin);
        factory.grantRole(factory.MARKET_ADMIN_ROLE(), admin);
        house.grantRole(house.MARKET_ADMIN_ROLE(), address(factory));
        amm.grantRole(amm.MARKET_ADMIN_ROLE(), address(factory));
        vm.stopPrank();
    }

    function _singleCreators() internal pure returns (bytes32[] memory creators) {
        creators = new bytes32[](1);
        creators[0] = CREATOR_A;
    }

    function test_CreateSingleNameMarketEndToEnd() public {
        vm.prank(admin);
        factory.createMarket(1, 0, METRIC, _singleCreators(), PRICE, DEPTH);

        assertTrue(factory.marketExists(1));
        assertEq(factory.marketTypeOf(1), 0);
        assertEq(factory.metricOf(1), METRIC);
        bytes32[] memory creators = factory.creatorIdsOf(1);
        assertEq(creators.length, 1);
        assertEq(creators[0], CREATOR_A);

        assertTrue(amm.marketExists(1));
        assertEq(amm.markPrice(1), PRICE);

        (uint8 kind, bytes32 metricId) = house.priceSources(1);
        assertEq(kind, 0);
        assertEq(metricId, METRIC);
    }

    function test_CreateIndexMarketWiresIndexSource() public {
        bytes32[] memory creators = new bytes32[](2);
        creators[0] = CREATOR_A;
        creators[1] = CREATOR_B;

        vm.prank(admin);
        factory.createMarket(2, 1, keccak256("index:tiktok-top5"), creators, PRICE, DEPTH);

        assertEq(factory.marketTypeOf(2), 1);
        bytes32[] memory stored = factory.creatorIdsOf(2);
        assertEq(stored.length, 2);
        assertEq(stored[1], CREATOR_B);

        (uint8 kind, bytes32 metricId) = house.priceSources(2);
        assertEq(kind, 1); // index oracle
        assertEq(metricId, keccak256("index:tiktok-top5"));
    }

    function test_Guards() public {
        vm.startPrank(admin);
        factory.createMarket(1, 0, METRIC, _singleCreators(), PRICE, DEPTH);

        vm.expectRevert(WavvyFactory.MarketExists.selector);
        factory.createMarket(1, 0, METRIC, _singleCreators(), PRICE, DEPTH);

        bytes32[] memory two = new bytes32[](2);
        two[0] = CREATOR_A;
        two[1] = CREATOR_B;
        vm.expectRevert(WavvyFactory.InvalidMarketParams.selector);
        factory.createMarket(3, 0, METRIC, two, PRICE, DEPTH);

        bytes32[] memory none = new bytes32[](0);
        vm.expectRevert(WavvyFactory.InvalidMarketParams.selector);
        factory.createMarket(4, 1, METRIC, none, PRICE, DEPTH);

        vm.expectRevert(WavvyFactory.InvalidMarketParams.selector);
        factory.createMarket(5, 0, METRIC, _singleCreators(), 0, DEPTH);

        vm.expectRevert(WavvyFactory.InvalidMarketParams.selector);
        factory.createMarket(6, 0, bytes32(0), _singleCreators(), PRICE, DEPTH);
        vm.stopPrank();
    }

    function test_CreationIsRoleGated() public {
        bytes32 role = factory.MARKET_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        factory.createMarket(1, 0, METRIC, _singleCreators(), PRICE, DEPTH);
    }
}
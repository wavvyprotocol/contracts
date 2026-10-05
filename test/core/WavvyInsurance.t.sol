// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { WavvyInsurance } from "../../contracts/core/WavvyInsurance.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { MockERC20 } from "./mocks/Mocks.sol";

contract WavvyInsuranceTest is Test {
    MockERC20 internal usdc;
    WavvyVault internal vault;
    WavvyInsurance internal insurance;

    address internal admin = address(0xA11CE);
    address internal house = address(0x40E5E);
    address internal treasury = address(0x7E45);
    address internal stranger = address(0xDEAD);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        vault = new WavvyVault(usdc, admin);
        insurance = new WavvyInsurance(vault, admin);

        bytes32 houseRole = insurance.HOUSE_ROLE();
        vm.prank(admin);
        insurance.grantRole(houseRole, house);
        usdc.mint(admin, 1_000e18);
    }

    function _fund(uint256 amount) internal {
        vm.startPrank(admin);
        usdc.approve(address(insurance), amount);
        insurance.fund(amount);
        vm.stopPrank();
    }

    function test_FundMovesTokensIntoVaultAccount() public {
        _fund(500e18);

        assertEq(insurance.balance(), 500e18);
        assertEq(vault.balanceOf(address(insurance)), 500e18);
        assertEq(usdc.balanceOf(address(vault)), 500e18);
        assertEq(usdc.balanceOf(admin), 500e18);
    }

    function test_FundGuards() public {
        vm.prank(admin);
        vm.expectRevert(WavvyInsurance.ZeroAmount.selector);
        insurance.fund(0);

        usdc.mint(stranger, 1e18);
        vm.startPrank(stranger);
        usdc.approve(address(insurance), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        insurance.fund(1e18);
        vm.stopPrank();
    }

    function test_CoverBadDebtMovesFundsToCaller() public {
        _fund(500e18);

        vm.prank(house);
        uint256 covered = insurance.coverBadDebt(200e18);

        assertEq(covered, 200e18);
        assertEq(vault.balanceOf(house), 200e18);
        assertEq(insurance.balance(), 300e18);
        assertEq(insurance.totalCovered(), 200e18);
    }

    function test_CoverCapsAtBalance() public {
        _fund(300e18);

        vm.prank(house);
        uint256 covered = insurance.coverBadDebt(1_000e18);

        assertEq(covered, 300e18);
        assertEq(insurance.balance(), 0);
        assertEq(vault.balanceOf(house), 300e18);
    }

    function test_CoverIsHouseOnly() public {
        _fund(100e18);
        bytes32 houseRole = insurance.HOUSE_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, houseRole)
        );
        insurance.coverBadDebt(1e18);
    }

    function test_WithdrawIsAdminOnly() public {
        _fund(400e18);

        vm.prank(admin);
        insurance.withdraw(treasury, 150e18);
        assertEq(vault.balanceOf(treasury), 150e18);
        assertEq(insurance.balance(), 250e18);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        insurance.withdraw(stranger, 1e18);
    }
}
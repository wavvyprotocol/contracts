// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { MockERC20 } from "./mocks/Mocks.sol";

contract WavvyVaultTest is Test {
    WavvyVault internal vault;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal stranger = address(0xDEAD);
    address internal house = address(0x40E5E);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new WavvyVault(usdc, admin);
    }

    function _deposit(address who, uint256 amountToken) internal {
        usdc.mint(who, amountToken);
        vm.startPrank(who);
        usdc.approve(address(vault), amountToken);
        vault.deposit(amountToken);
        vm.stopPrank();
    }

    function test_DepositScalesToWad() public {
        _deposit(alice, 1_000_000); // 1 USDC at 6 decimals

        assertEq(vault.balanceOf(alice), 1e18);
        assertEq(vault.totalBalances(), 1e18);
        assertEq(usdc.balanceOf(address(vault)), 1_000_000);
    }

    function test_WithdrawReturnsTokenUnits() public {
        _deposit(alice, 1_000_000);
        vm.prank(alice);
        vault.withdraw(500_000);

        assertEq(vault.balanceOf(alice), 0.5e18);
        assertEq(usdc.balanceOf(alice), 500_000);
        assertGe(usdc.balanceOf(address(vault)), vault.totalBalances() / 1e12);
    }

    function test_ZeroAmountReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(WavvyVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.expectRevert(WavvyVault.ZeroAmount.selector);
        vault.withdraw(0);
        vm.stopPrank();
    }

    function test_WithdrawBeyondBalanceReverts() public {
        _deposit(alice, 1_000_000);
        vm.prank(alice);
        vm.expectRevert(WavvyVault.InsufficientBalance.selector);
        vault.withdraw(2_000_000);
    }

    function test_TransferAuthRules() public {
        _deposit(alice, 2_000_000);

        // Self-authorized transfer.
        vm.prank(alice);
        vault.transfer(alice, bob, 1e18);
        assertEq(vault.balanceOf(bob), 1e18);

        // A third party cannot move someone else's funds.
        vm.prank(stranger);
        vm.expectRevert(WavvyVault.UnauthorizedTransfer.selector);
        vault.transfer(alice, bob, 1e18);

        // The house role can move accounts because it settles positions.
        bytes32 houseRole = vault.HOUSE_ROLE();
        vm.prank(admin);
        vault.grantRole(houseRole, house);
        vm.prank(house);
        vault.transfer(alice, bob, 1e18);
        assertEq(vault.balanceOf(bob), 2e18);
    }

    function test_TransferBeyondBalanceReverts() public {
        _deposit(alice, 1_000_000);
        vm.prank(alice);
        vm.expectRevert(WavvyVault.InsufficientBalance.selector);
        vault.transfer(alice, bob, 2e18);
    }

    function test_SystemRolePullsOnlyIntoItself() public {
        _deposit(alice, 1_000_000);

        bytes32 systemRole = vault.SYSTEM_ROLE();
        vm.prank(admin);
        vault.grantRole(systemRole, address(this));

        // Pulling a user's free balance into the system contract is allowed.
        vault.transfer(alice, address(this), 0.5e18);
        assertEq(vault.balanceOf(address(this)), 0.5e18);

        // Sending it to a third party is not.
        vm.expectRevert(WavvyVault.UnauthorizedTransfer.selector);
        vault.transfer(alice, bob, 0.1e18);
    }

    function test_EighteenDecimalTokenIsIdentity() public {
        MockERC20 token18 = new MockERC20("Wad", "WAD", 18);
        WavvyVault vault18 = new WavvyVault(token18, admin);

        token18.mint(alice, 5e18);
        vm.startPrank(alice);
        token18.approve(address(vault18), 5e18);
        vault18.deposit(5e18);
        assertEq(vault18.balanceOf(alice), 5e18);
        vault18.withdraw(5e18);
        vm.stopPrank();
        assertEq(token18.balanceOf(alice), 5e18);
        assertEq(vault18.totalBalances(), 0);
    }

    function test_BackingInvariantAfterFlows() public {
        _deposit(alice, 3_000_000);
        _deposit(bob, 1_000_000);
        vm.prank(alice);
        vault.transfer(alice, bob, 0.75e18);
        vm.prank(bob);
        vault.withdraw(200_000);

        assertGe(usdc.balanceOf(address(vault)) * 1e12, vault.totalBalances());
    }
}
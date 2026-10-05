// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { MockUSDC } from "../../contracts/mocks/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC internal usdc;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal stranger = address(0xDEAD);

    function setUp() public {
        usdc = new MockUSDC(admin);
    }

    function test_EighteenDecimals() public view {
        assertEq(usdc.decimals(), 18);
        assertEq(usdc.name(), "Mock USDC");
        assertEq(usdc.symbol(), "USDC");
    }

    function test_MintIsRoleGated() public {
        vm.prank(admin);
        usdc.mint(alice, 1_000e18);
        assertEq(usdc.balanceOf(alice), 1_000e18);

        bytes32 minterRole = usdc.MINTER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, minterRole)
        );
        usdc.mint(stranger, 1e18);
    }
}
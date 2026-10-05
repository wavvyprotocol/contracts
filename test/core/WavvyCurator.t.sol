// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { WavvyCurator } from "../../contracts/core/WavvyCurator.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { MockERC20 } from "./mocks/Mocks.sol";

contract WavvyCuratorTest is Test {
    MockERC20 internal usdc;
    WavvyVault internal vault;
    WavvyCurator internal curator;

    address internal admin = address(0xA11CE);
    address internal house = address(0x40E5E);
    address internal alice = address(0xA1);
    address internal stranger = address(0xDEAD);

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 18);
        vault = new WavvyVault(usdc, admin);
        curator = new WavvyCurator(vault, admin);

        vm.startPrank(admin);
        curator.grantRole(curator.HOUSE_ROLE(), house);
        vault.grantRole(vault.SYSTEM_ROLE(), address(curator));
        vm.stopPrank();

        usdc.mint(alice, 1_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18);
        vm.stopPrank();
    }

    function test_CreateCallLocksStake() public {
        vm.prank(alice);
        uint256 callId = curator.createCall(7, true, 100e18);

        assertEq(vault.balanceOf(address(curator)), 100e18);
        assertEq(vault.balanceOf(alice), 900e18);
        assertEq(curator.callCurator(callId), alice);
        assertEq(curator.copiesOf(callId), 0);

        (address callOwner, uint256 marketId, bool isLong, uint256 stake,, bool active) = curator.callInfo(callId);
        assertEq(callOwner, alice);
        assertEq(marketId, 7);
        assertTrue(isLong);
        assertEq(stake, 100e18);
        assertTrue(active);
    }

    function test_CreateCallRequiresStake() public {
        vm.prank(alice);
        vm.expectRevert(WavvyCurator.StakeRequired.selector);
        curator.createCall(7, true, 0);
    }

    function test_CloseCallReleasesStakeToCurator() public {
        vm.prank(alice);
        uint256 callId = curator.createCall(7, true, 100e18);

        vm.prank(stranger);
        vm.expectRevert(WavvyCurator.NotCallCurator.selector);
        curator.closeCall(callId);

        vm.prank(alice);
        curator.closeCall(callId);
        assertEq(vault.balanceOf(alice), 1_000e18);
        assertEq(vault.balanceOf(address(curator)), 0);

        vm.prank(alice);
        vm.expectRevert(WavvyCurator.CallAlreadyClosed.selector);
        curator.closeCall(callId);
    }

    function test_RecordCopyIsHouseOnly() public {
        vm.prank(alice);
        uint256 callId = curator.createCall(7, true, 100e18);

        vm.prank(house);
        curator.recordCopy(callId, 42);
        assertEq(curator.attributionOf(42), callId);
        assertEq(curator.copiesOf(callId), 1);

        vm.prank(house);
        vm.expectRevert(WavvyCurator.AlreadyAttributed.selector);
        curator.recordCopy(callId, 42);

        bytes32 houseRole = curator.HOUSE_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, houseRole)
        );
        curator.recordCopy(callId, 43);
    }

    function test_RecordCopyGuards() public {
        vm.prank(house);
        vm.expectRevert(WavvyCurator.UnknownCall.selector);
        curator.recordCopy(99, 1);

        vm.prank(alice);
        uint256 callId = curator.createCall(7, true, 100e18);
        vm.prank(alice);
        curator.closeCall(callId);

        vm.prank(house);
        vm.expectRevert(WavvyCurator.CallAlreadyClosed.selector);
        curator.recordCopy(callId, 2);
    }

    function test_CopyFeeCreditAndClaim() public {
        vm.prank(alice);
        uint256 callId = curator.createCall(7, true, 100e18);

        vm.prank(house);
        curator.creditCopyFee(callId, 25e18);
        assertEq(curator.claimable(alice), 25e18);

        uint256 before = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = curator.claim();
        assertEq(claimed, 25e18);
        assertEq(vault.balanceOf(alice), before + 25e18);
        assertEq(curator.claimable(alice), 0);

        vm.prank(stranger);
        vm.expectRevert(WavvyCurator.NothingToClaim.selector);
        curator.claim();
    }

    function test_CreditGuards() public {
        vm.prank(house);
        vm.expectRevert(WavvyCurator.UnknownCall.selector);
        curator.creditCopyFee(99, 1e18);

        bytes32 houseRole = curator.HOUSE_ROLE();
        vm.prank(alice);
        uint256 callId = curator.createCall(7, true, 100e18);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, houseRole)
        );
        curator.creditCopyFee(callId, 1e18);
    }
}
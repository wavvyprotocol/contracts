// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { WavvyCreatorRewards } from "../../contracts/core/WavvyCreatorRewards.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { MockERC20 } from "./mocks/Mocks.sol";

contract WavvyCreatorRewardsTest is Test {
    MockERC20 internal usdc;
    WavvyVault internal vault;
    WavvyCreatorRewards internal rewards;

    address internal admin = address(0xA11CE);
    address internal house = address(0x40E5E);
    address internal grantsPool = address(0x6EA27);
    address internal creatorWallet = address(0xC12E);
    address internal newWallet = address(0xC12F);
    address internal stranger = address(0xDEAD);

    bytes32 internal constant CREATOR = keccak256("spotify:artist-a");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 18);
        vault = new WavvyVault(usdc, admin);
        rewards = new WavvyCreatorRewards(vault, grantsPool, admin);
        bytes32 houseRole = rewards.HOUSE_ROLE();
        vm.prank(admin);
        rewards.grantRole(houseRole, house);
    }

    function _accrue(uint256 amount) internal {
        usdc.mint(house, amount);
        vm.startPrank(house);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        // House moves the fee into the rewards account, then records it.
        vault.transfer(house, address(rewards), amount);
        vm.stopPrank();
        vm.prank(house);
        rewards.accrue(CREATOR, amount);
    }

    function test_AccrueIsHouseOnlyAndTracksBalance() public {
        _accrue(75e18);
        assertEq(rewards.balanceOfCreator(CREATOR), 75e18);
        assertEq(vault.balanceOf(address(rewards)), 75e18);

        bytes32 houseRole = rewards.HOUSE_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, houseRole)
        );
        rewards.accrue(CREATOR, 1e18);
    }

    function test_ClaimAfterWalletLink() public {
        _accrue(50e18);

        vm.prank(admin);
        rewards.linkWallet(CREATOR, creatorWallet);

        vm.prank(creatorWallet);
        uint256 amount = rewards.claim(CREATOR);
        assertEq(amount, 50e18);
        assertEq(vault.balanceOf(creatorWallet), 50e18);
        assertEq(rewards.balanceOfCreator(CREATOR), 0);

        vm.prank(creatorWallet);
        vm.expectRevert(WavvyCreatorRewards.ZeroAmount.selector);
        rewards.claim(CREATOR);
    }

    function test_ClaimGuards() public {
        _accrue(10e18);

        vm.prank(creatorWallet);
        vm.expectRevert(WavvyCreatorRewards.NoWalletLinked.selector);
        rewards.claim(CREATOR);

        vm.prank(admin);
        rewards.linkWallet(CREATOR, creatorWallet);

        vm.prank(stranger);
        vm.expectRevert(WavvyCreatorRewards.NotCreatorWallet.selector);
        rewards.claim(CREATOR);
    }

    function test_WalletLinkAndChangeFlow() public {
        vm.startPrank(admin);
        rewards.linkWallet(CREATOR, creatorWallet);

        vm.expectRevert(WavvyCreatorRewards.WalletAlreadyLinked.selector);
        rewards.linkWallet(CREATOR, newWallet);

        rewards.requestWalletChange(CREATOR, newWallet);
        vm.stopPrank();

        vm.expectRevert(WavvyCreatorRewards.WalletChangePending.selector);
        rewards.finalizeWalletChange(CREATOR);

        vm.warp(block.timestamp + rewards.walletChangeDelay() + 1);
        rewards.finalizeWalletChange(CREATOR);

        (address wallet,,,) = rewards.creatorInfo(CREATOR);
        assertEq(wallet, newWallet);
    }

    function test_LinkGuardsAndNoPending() public {
        vm.startPrank(admin);
        vm.expectRevert(WavvyCreatorRewards.InvalidAddress.selector);
        rewards.linkWallet(CREATOR, address(0));

        vm.expectRevert(WavvyCreatorRewards.NoWalletLinked.selector);
        rewards.requestWalletChange(CREATOR, newWallet);
        vm.stopPrank();

        vm.expectRevert(WavvyCreatorRewards.NoPendingWallet.selector);
        rewards.finalizeWalletChange(CREATOR);
    }

    function test_SweepAfterClaimWindow() public {
        _accrue(60e18);

        vm.expectRevert(WavvyCreatorRewards.ClaimWindowActive.selector);
        rewards.sweep(CREATOR);

        vm.warp(block.timestamp + rewards.claimWindow() + 1);
        uint256 swept = rewards.sweep(CREATOR);

        assertEq(swept, 60e18);
        assertEq(vault.balanceOf(grantsPool), 60e18);
        assertEq(rewards.balanceOfCreator(CREATOR), 0);

        vm.expectRevert(WavvyCreatorRewards.NothingToSweep.selector);
        rewards.sweep(CREATOR);
    }

    function test_CancelPendingWalletChange() public {
        vm.startPrank(admin);
        rewards.linkWallet(CREATOR, creatorWallet);
        rewards.requestWalletChange(CREATOR, newWallet);
        rewards.cancelWalletChange(CREATOR);
        vm.stopPrank();

        (address wallet, address pending,,) = rewards.creatorInfo(CREATOR);
        assertEq(wallet, creatorWallet);
        assertEq(pending, address(0));

        vm.expectRevert(WavvyCreatorRewards.NoPendingWallet.selector);
        rewards.finalizeWalletChange(CREATOR);
    }

    function test_SettingZeroDurationsRejected() public {
        vm.startPrank(admin);
        vm.expectRevert(WavvyCreatorRewards.InvalidParams.selector);
        rewards.setClaimWindow(0);

        vm.expectRevert(WavvyCreatorRewards.InvalidParams.selector);
        rewards.setWalletChangeDelay(0);
        vm.stopPrank();
    }
}

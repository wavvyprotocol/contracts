// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { WavvyPosition } from "../../contracts/core/WavvyPosition.sol";
import { IPosition } from "../../contracts/interfaces/IPosition.sol";

contract WavvyPositionTest is Test {
    WavvyPosition internal position;

    address internal admin = address(0xA11CE);
    address internal house = address(0x40E5E);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal stranger = address(0xDEAD);

    function setUp() public {
        vm.warp(1_000_000);
        position = new WavvyPosition(admin);
        bytes32 houseRole = position.HOUSE_ROLE();
        vm.prank(admin);
        position.grantRole(houseRole, house);
    }

    function _data(bool isLong) internal view returns (IPosition.PositionData memory) {
        return IPosition.PositionData({
            marketId: 7,
            isLong: isLong,
            size: 3e18,
            entryPrice: 1000e18,
            margin: 100e18,
            lastFundingGrowth: -5e15,
            openedAt: uint64(block.timestamp),
            callId: 0
        });
    }

    function _hasPrefix(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory v = bytes(value);
        bytes memory p = bytes(prefix);
        if (v.length < p.length) return false;
        for (uint256 i; i < p.length; ++i) {
            if (v[i] != p[i]) return false;
        }
        return true;
    }

    function test_MintStoresPositionAndMetadata() public {
        vm.prank(house);
        uint256 tokenId = position.mintPosition(alice, _data(true));

        assertEq(position.ownerOf(tokenId), alice);
        assertTrue(position.exists(tokenId));
        assertEq(position.totalMargin(), 100e18);

        IPosition.PositionData memory p = position.getPosition(tokenId);
        assertEq(p.marketId, 7);
        assertTrue(p.isLong);
        assertEq(p.size, 3e18);
        assertEq(p.entryPrice, 1000e18);
        assertEq(p.margin, 100e18);
        assertEq(p.lastFundingGrowth, -5e15);

        string memory uri = position.tokenURI(tokenId);
        assertTrue(_hasPrefix(uri, "data:application/json;base64,"));
        assertGt(bytes(uri).length, 200);
    }

    function test_MintIsHouseOnly() public {
        bytes32 houseRole = position.HOUSE_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, houseRole)
        );
        position.mintPosition(stranger, _data(true));
    }

    function test_UpdateAndBurnAdjustMarginInvariant() public {
        vm.prank(house);
        uint256 tokenId = position.mintPosition(alice, _data(true));

        vm.prank(house);
        position.updatePosition(tokenId, 1.5e18, 40e18, 7e15);
        assertEq(position.totalMargin(), 40e18);
        IPosition.PositionData memory p = position.getPosition(tokenId);
        assertEq(p.size, 1.5e18);
        assertEq(p.margin, 40e18);
        assertEq(p.lastFundingGrowth, 7e15);

        vm.prank(house);
        position.burnPosition(tokenId);
        assertFalse(position.exists(tokenId));
        assertEq(position.totalMargin(), 0);

        vm.expectRevert(WavvyPosition.NoToken.selector);
        position.getPosition(tokenId);
        vm.expectRevert(WavvyPosition.NoToken.selector);
        position.tokenURI(tokenId);
    }

    function test_TransferMovesOwnershipKeepsAccounting() public {
        vm.prank(house);
        uint256 tokenId = position.mintPosition(alice, _data(true));

        vm.prank(alice);
        position.transferFrom(alice, bob, tokenId);

        assertEq(position.ownerOf(tokenId), bob);
        assertEq(position.totalMargin(), 100e18);
        IPosition.PositionData memory p = position.getPosition(tokenId);
        assertEq(p.margin, 100e18);
        assertEq(p.lastFundingGrowth, -5e15);
    }

    function test_MetadataDiffersBySide() public {
        vm.prank(house);
        uint256 longId = position.mintPosition(alice, _data(true));
        vm.prank(house);
        uint256 shortId = position.mintPosition(alice, _data(false));

        assertFalse(
            keccak256(bytes(position.tokenURI(longId))) == keccak256(bytes(position.tokenURI(shortId)))
        );
    }

    function test_SupportsInterfaces() public view {
        assertTrue(position.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(position.supportsInterface(0x7965db0b)); // AccessControl
        assertFalse(position.supportsInterface(0xffffffff));
    }
}
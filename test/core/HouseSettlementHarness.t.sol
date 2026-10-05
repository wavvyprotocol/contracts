// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { WavvyHouse } from "../../contracts/core/WavvyHouse.sol";
import { WavvyInsurance } from "../../contracts/core/WavvyInsurance.sol";
import { WavvyPosition } from "../../contracts/core/WavvyPosition.sol";
import { WavvyVault } from "../../contracts/core/WavvyVault.sol";
import { IWavvyAMM } from "../../contracts/interfaces/IWavvyAMM.sol";
import { IWavvyIndexOracle } from "../../contracts/interfaces/IWavvyIndexOracle.sol";
import { IWavvyOracle } from "../../contracts/interfaces/IWavvyOracle.sol";
import { IWavvyVault } from "../../contracts/interfaces/IWavvyVault.sol";
import { MockERC20 } from "./mocks/Mocks.sol";

/// @dev Exposes the internal settlement routine so zero-value settlement paths
/// can be tested directly.
contract HouseHarness is WavvyHouse {
    constructor(IWavvyVault vault_, address treasury_, address admin)
        WavvyHouse(vault_, IWavvyAMM(address(0)), IWavvyOracle(address(0)), IWavvyIndexOracle(address(0)), treasury_, admin)
    {}

    function settle(
        uint256 tokenId,
        address holder,
        uint256 marketId,
        uint256 marginIn,
        int256 pnl,
        int256 fundingCost,
        uint256 fee,
        uint256 penalty,
        address liquidator,
        bool allowBadDebt
    ) external returns (uint256 payout, uint256 liquidatorPaid) {
        return _settle(tokenId, holder, marketId, marginIn, pnl, fundingCost, fee, penalty, liquidator, allowBadDebt);
    }
}

/// @notice A break-even settlement must not revert on a zero-value transfer.
contract HouseSettlementHarnessTest is Test {
    MockERC20 internal usdc;
    WavvyVault internal vault;
    WavvyPosition internal position;
    WavvyInsurance internal insurance;
    HouseHarness internal harness;

    address internal admin = address(0xA11CE);
    address internal treasury = address(0x7E45);
    address internal alice = address(0xA1);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        vault = new WavvyVault(usdc, admin);
        position = new WavvyPosition(admin);
        insurance = new WavvyInsurance(vault, admin);
        harness = new HouseHarness(vault, treasury, admin);

        bytes32 insuranceRole = insurance.HOUSE_ROLE();
        bytes32 houseRole = vault.HOUSE_ROLE();
        bytes32 positionRole = position.HOUSE_ROLE();
        vm.startPrank(admin);
        insurance.grantRole(insuranceRole, address(harness));
        vault.grantRole(houseRole, address(harness));
        position.grantRole(positionRole, address(harness));
        harness.setSystem(
            address(position), address(0), address(insurance), address(0), address(0), address(0)
        );
        vm.stopPrank();

        // Fund the position account so settlement transfers have a source.
        usdc.mint(address(this), 100e18);
        usdc.approve(address(vault), 100e18);
        vault.deposit(100e18);
        vault.transfer(address(this), address(position), 100e18);
    }

    function test_BreakEvenSettlementDoesNotRevert() public {
        (uint256 payout, uint256 liquidatorPaid) =
            harness.settle(1, alice, 1, 0, int256(0), int256(0), 0, 0, address(0), true);

        assertEq(payout, 0);
        assertEq(liquidatorPaid, 0);
    }

    function test_ZeroMarginBadDebtSettlementDoesNotRevert() public {
        vm.expectEmit(true, false, false, false, address(harness));
        emit WavvyHouse.BadDebt(1, 0, 0);

        (uint256 payout, uint256 liquidatorPaid) =
            harness.settle(1, alice, 1, 0, int256(-1e18), int256(0), 0, 0, address(0), true);

        assertEq(payout, 0);
        assertEq(liquidatorPaid, 0);
    }

    function test_ZeroPayoutWithMarginDoesNotRevert() public {
        // Margin exactly covers the loss: payout is zero and the loss moves to
        // the treasury without any zero-value transfer.
        (uint256 payout,) = harness.settle(1, alice, 1, 100e18, int256(-100e18), int256(0), 0, 0, address(0), true);
        assertEq(payout, 0);
    }
}
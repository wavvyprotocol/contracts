// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IWavvyTimelock } from "../interfaces/IWavvyTimelock.sol";

/// @notice Protocol governance timelock. Every admin action in the system is scheduled and executed through this contract: risk parameter changes, market pauses, role grants, and contract upgrades.
///
/// The delay is deploy configuration: short on testnet for iteration speed, 24 to 48 hours on mainnet so users can exit before a risky change lands.
contract WavvyTimelock is TimelockController, IWavvyTimelock {
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {}

    function getMinDelay() public view override(TimelockController, IWavvyTimelock) returns (uint256) {
        return super.getMinDelay();
    }

    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        public
        pure
        override(TimelockController, IWavvyTimelock)
        returns (bytes32)
    {
        return super.hashOperation(target, value, data, predecessor, salt);
    }

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override(TimelockController, IWavvyTimelock) {
        super.schedule(target, value, data, predecessor, salt, delay);
    }

    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        public
        payable
        override(TimelockController, IWavvyTimelock)
    {
        super.execute(target, value, payload, predecessor, salt);
    }

    function cancel(bytes32 id) public override(TimelockController, IWavvyTimelock) {
        super.cancel(id);
    }
}
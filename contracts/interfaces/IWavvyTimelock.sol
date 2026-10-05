// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IWavvyTimelock {
    function getMinDelay() external view returns (uint256);

    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        pure
        returns (bytes32);

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        external
        payable;

    function cancel(bytes32 id) external;
}
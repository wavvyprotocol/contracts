// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice CRE consumer entrypoint. The workflow delivers an ABI-encoded
/// payload that the consumer decodes, the sender is authenticated in the
/// consumer implementation through its reporter role.
interface IReceiver {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
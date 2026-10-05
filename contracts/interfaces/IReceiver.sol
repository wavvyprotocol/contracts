// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice CRE consumer entrypoint. The workflow delivers an ABI-encoded
/// payload that the consumer decodes; the consumer authenticates the sender
/// (forwarder address and reporter role) and validates the workflow metadata
/// before accepting a report.
///
/// The interface extends IERC165 because the Keystone forwarder checks ERC165
/// support before delivering reports.
interface IReceiver is IERC165 {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
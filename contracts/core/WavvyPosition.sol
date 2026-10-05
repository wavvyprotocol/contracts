// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IPosition } from "../interfaces/IPosition.sol";

/// @notice Position ledger and NFT. One token per open position.
///
/// Margin, size, entry price, and the funding checkpoint are attached to the token id, never to an address: transferring the NFT moves the whole
/// position, and the house resolves ownership through `ownerOf` at call time. Liquidation therefore always pays the current holder.
///
/// Metadata is generated onchain as a base64 data URI with an SVG image
contract WavvyPosition is ERC721, AccessControl, IPosition {
    bytes32 public constant HOUSE_ROLE = keccak256("HOUSE_ROLE");

    uint256 private _nextId = 1;
    uint256 public totalMargin;

    mapping(uint256 => PositionData) private _positions;
    mapping(uint256 => bool) private _exists;

    error NoToken();
    error HouseOnly();

    event PositionMinted(uint256 indexed tokenId, address indexed holder, uint256 indexed marketId);
    event PositionUpdated(uint256 indexed tokenId, uint256 size, uint256 margin, int256 lastFundingGrowth);
    event PositionBurned(uint256 indexed tokenId);

    constructor(address admin) ERC721("Wavvy Position", "WVY-POS") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function mintPosition(address to, PositionData calldata data)
        external
        override
        onlyRole(HOUSE_ROLE)
        returns (uint256 tokenId)
    {
        tokenId = _nextId++;
        _positions[tokenId] = data;
        _exists[tokenId] = true;
        totalMargin += data.margin;
        _mint(to, tokenId);
        emit PositionMinted(tokenId, to, data.marketId);
    }

    function burnPosition(uint256 tokenId) external override onlyRole(HOUSE_ROLE) {
        if (!_exists[tokenId]) revert NoToken();
        totalMargin -= _positions[tokenId].margin;
        delete _positions[tokenId];
        delete _exists[tokenId];
        _burn(tokenId);
        emit PositionBurned(tokenId);
    }

    function updatePosition(uint256 tokenId, uint256 size, uint256 margin, int256 lastFundingGrowth)
        external
        override
        onlyRole(HOUSE_ROLE)
    {
        if (!_exists[tokenId]) revert NoToken();
        PositionData storage p = _positions[tokenId];
        totalMargin = totalMargin - p.margin + margin;
        p.size = size;
        p.margin = margin;
        p.lastFundingGrowth = lastFundingGrowth;
        emit PositionUpdated(tokenId, size, margin, lastFundingGrowth);
    }

    function getPosition(uint256 tokenId) external view override returns (PositionData memory) {
        if (!_exists[tokenId]) revert NoToken();
        return _positions[tokenId];
    }

    function exists(uint256 tokenId) external view override returns (bool) {
        return _exists[tokenId];
    }

    function ownerOf(uint256 tokenId) public view override(ERC721, IPosition) returns (address) {
        return super.ownerOf(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return ERC721.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists[tokenId]) revert NoToken();
        PositionData memory p = _positions[tokenId];
        string memory svg = _renderSvg(tokenId, p);
        string memory json = string.concat(
            '{"name":"Wavvy Position #',
            Strings.toString(tokenId),
            '","description":"Perpetual position on a Wavvy attention market.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev Generative art: a market-derived gradient, a side band for long or short, and the token id. Cheap to render, deterministic per token.
    function _renderSvg(uint256 tokenId, PositionData memory p) internal pure returns (string memory) {
        uint256 hue = uint256(keccak256(abi.encodePacked(p.marketId))) % 360;
        string memory band = p.isLong ? "#22C55E" : "#EF4444";
        string memory side = p.isLong ? "LONG" : "SHORT";
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 400 400">',
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0%" stop-color="#E93992"/><stop offset="100%" stop-color="hsl(',
            Strings.toString(hue),
            ',65%,25%)"/></linearGradient></defs>',
            '<rect width="400" height="400" fill="url(#g)"/>',
            '<rect x="0" y="0" width="18" height="400" fill="',
            band,
            '"/>',
            '<text x="40" y="200" fill="#F5F5F7" font-family="monospace" font-size="34">WVY-POS #',
            Strings.toString(tokenId),
            "</text>",
            '<text x="40" y="240" fill="#F5F5F7" font-family="monospace" font-size="22">',
            side,
            " ",
            Strings.toString(p.marketId),
            "</text></svg>"
        );
    }
}
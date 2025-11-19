// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SoulboundToken is ERC721URIStorage, Ownable {
    bool public immutable burnable;
    bool public immutable revocable;
    bool public ownershipLocked;

    mapping(uint256 => bool) public revoked;

    constructor(
        string memory _name,
        string memory _symbol,
        bool _burnable,
        bool _revocable,
        address initialOwner
    ) ERC721(_name, _symbol) Ownable(initialOwner) {
        burnable = _burnable;
        revocable = _revocable;
    }

    function mint(address to, uint256 tokenId, string memory uri) public onlyOwner {
        _mint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function burn(uint256 tokenId) public {
        require(burnable, "Burn disabled");
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        _burn(tokenId);
    }

    function revoke(uint256 tokenId) public onlyOwner {
        require(revocable, "Revoke disabled");
        revoked[tokenId] = true;
    }

    /// One-time permanent ownership transfer
    function transferOwnershipPermanent(address newOwner) external onlyOwner {
        require(!ownershipLocked, "Ownership already locked");
        require(newOwner != address(0), "Invalid address");
        _transferOwnership(newOwner);
        ownershipLocked = true;
    }

    /// 🚫 Soulbound logic: block transfers
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);

        // Allow mint (from == 0) and burn (to == 0), block others
        require(from == address(0) || to == address(0), "SBTs are soulbound");

        return super._update(to, tokenId, auth);
    }
}

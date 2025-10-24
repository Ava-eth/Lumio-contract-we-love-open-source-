// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * @title DomainBoundNFT
 * @notice NFT collection linked to Space ID domains. A user can mint only if their wallet owns a domain.
 *         The NFT stores the domain name and prevents another mint with the same domain. 
 *         If the domain changes ownership, the NFT becomes open for bidding — only the new domain owner can buy it.
 */

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IVerifierOracle {
    function verifyDomain(address user, string calldata domain) external view returns (bool);
}

contract DomainBoundNFT is ERC721URIStorage, Ownable, ReentrancyGuard, Pausable {
    uint256 private _tokenIdCounter;

    IVerifierOracle public verifier;
    address public treasury;

    struct DomainNFT {
        string domain;
        bool flaggedForBid;
        uint256 bidPrice;
    }

    mapping(string => uint256) public domainToTokenId;
    mapping(uint256 => DomainNFT) public nftData;
    mapping(uint256 => address) public bids;
    mapping(address => uint256) public pendingWithdrawals;

    event Minted(address indexed user, string domain, uint256 tokenId);
    event OpenForBid(string domain, uint256 tokenId);
    event BidPlaced(address indexed bidder, uint256 tokenId, uint256 amount);
    event Sold(address indexed buyer, uint256 tokenId, uint256 amount);
    event Burned(uint256 tokenId);
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event Withdrawn(address indexed user, uint256 amount);

    constructor(address _verifier, address _treasury) ERC721("DomainBoundNFT", "DBN") Ownable(msg.sender) {
        require(_verifier != address(0), "Invalid verifier");
        require(_treasury != address(0), "Invalid treasury");
        verifier = IVerifierOracle(_verifier);
        treasury = _treasury;
    }

    modifier onlyTreasury() {
        require(msg.sender == treasury, "Not treasury");
        _;
    }

    function updateVerifier(address _verifier) external onlyTreasury {
        require(_verifier != address(0), "Invalid verifier");
        address oldVerifier = address(verifier);
        verifier = IVerifierOracle(_verifier);
        emit VerifierUpdated(oldVerifier, _verifier);
    }

    function updateTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function mint(string calldata domain, string calldata tokenURI_) external nonReentrant whenNotPaused {
        require(verifier.verifyDomain(msg.sender, domain), "You do not own this domain");
        require(domainToTokenId[domain] == 0, "Domain already minted");
        require(bytes(domain).length > 0, "Empty domain");

        _tokenIdCounter++;
        uint256 newTokenId = _tokenIdCounter;

        _safeMint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI_);

        domainToTokenId[domain] = newTokenId;
        nftData[newTokenId] = DomainNFT(domain, false, 0);

        emit Minted(msg.sender, domain, newTokenId);
    }

    function flagForBid(string calldata domain) external onlyOwner {
        uint256 tokenId = domainToTokenId[domain];
        require(tokenId != 0, "Invalid domain");
        nftData[tokenId].flaggedForBid = true;
        emit OpenForBid(domain, tokenId);
    }

    function placeBid(uint256 tokenId) external payable nonReentrant whenNotPaused {
        DomainNFT storage nft = nftData[tokenId];
        require(nft.flaggedForBid, "Not open for bid");
        require(verifier.verifyDomain(msg.sender, nft.domain), "Not current domain owner");
        require(msg.value > nft.bidPrice, "Bid too low");

        // Refund previous bidder using withdrawal pattern
        if (bids[tokenId] != address(0)) {
            pendingWithdrawals[bids[tokenId]] += nft.bidPrice;
        }

        nft.bidPrice = msg.value;
        bids[tokenId] = msg.sender;
        emit BidPlaced(msg.sender, tokenId, msg.value);
    }

    function finalizeBid(uint256 tokenId) external nonReentrant whenNotPaused {
        DomainNFT storage nft = nftData[tokenId];
        require(nft.flaggedForBid, "NFT not for sale");
        address buyer = bids[tokenId];
        require(buyer != address(0), "No bids");

        address seller = ownerOf(tokenId);
        uint256 salePrice = nft.bidPrice;
        
        // Update state before transfers
        nft.flaggedForBid = false;
        delete bids[tokenId];
        
        // Transfer NFT
        _transfer(seller, buyer, tokenId);
        
        // Add payment to seller's withdrawal balance
        pendingWithdrawals[seller] += salePrice;
        
        emit Sold(buyer, tokenId, salePrice);
    }
    
    /**
     * @notice Withdraw accumulated funds from bid refunds or sales
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        
        pendingWithdrawals[msg.sender] = 0;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
        
        emit Withdrawn(msg.sender, amount);
    }

    function burn(uint256 tokenId) external nonReentrant {
        require(msg.sender == ownerOf(tokenId) || msg.sender == owner(), "Not authorized");
        require(!nftData[tokenId].flaggedForBid, "Cannot burn NFT for sale");
        
        string memory domain = nftData[tokenId].domain;
        
        _burn(tokenId);
        delete domainToTokenId[domain];
        delete nftData[tokenId];
        delete bids[tokenId];
        
        emit Burned(tokenId);
    }
    
    /**
     * @notice Get pending withdrawal amount for an address
     * @param user Address to check
     * @return amount Amount available for withdrawal
     */
    function getPendingWithdrawal(address user) external view returns (uint256) {
        return pendingWithdrawals[user];
    }
    
    /**
     * @notice Get total number of NFTs minted
     * @return count Total token count
     */
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter;
    }

    receive() external payable {}
    fallback() external payable {}
}

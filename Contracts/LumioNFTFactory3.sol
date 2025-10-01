// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

/// @title NFT Collection Factory
/// @notice Deploys new NFT collections and manages platform fees
contract NFTsCollectionFactory is Ownable {
    // ============ State Variables ============
    address[] public deployedCollections;  // Stores addresses of all collections deployed
    address public treasury;               // Platform treasury (receives platform fees)
    uint256 public constant DEPLOYMENT_FEE = 1000 ether; // Fixed fee (non-editable)
    uint256 public constant COLLECTION_FEE = 500 ether;  // Fixed per collection mint fee
    uint256 public constant NFT_FEE = 50 ether;          // Fixed per NFT mint fee

    // ============ Events ============
    event CollectionDeployed(address indexed collection, address indexed deployer, string name, string symbol);
    event TreasuryUpdated(address indexed newTreasury);
    event TreasuryWithdrawn(address indexed treasury, uint256 amount);

    // ============ Constructor ============
    constructor() Ownable(msg.sender) {
    treasury = address(this); // always set treasury to the factory contract itself
}


    // ============ Admin Functions ============

    /// @notice Change treasury address
    /// @dev Only factory owner can change treasury
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @notice Withdraw all collected fees from factory to treasury
    /// @dev Only factory owner can call this
    /// @notice Withdraw accumulated platform fees from the factory contract
function withdrawTreasury() external onlyOwner {
    uint256 balance = address(this).balance;
    require(balance > 0, "No funds");

    // Send funds to the treasury wallet (can be the factory owner or another address)
    payable(treasury).transfer(balance);

    emit TreasuryWithdrawn(treasury, balance);
}


    // ============ Collection Deployment ============

    /// @notice Deploy a new NFT collection
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _baseURI Metadata base URI
    /// @param _royaltyFee Royalty fee (in basis points, e.g., 500 = 5%)
    /// @param _royaltyReceiver Address that receives royalties
    /// @param _mintPrice Mint price set by deployer (goes to deployer wallet)
    /// @param _maxSupply Maximum supply for the collection
    function createCollection(
        string memory _name,
        string memory _symbol,
        string memory _baseURI,
        uint96 _royaltyFee,
        address _royaltyReceiver,
        uint256 _mintPrice,
        uint256 _maxSupply
    ) external payable {
        // Require exact platform deployment fee
        require(msg.value >= DEPLOYMENT_FEE + COLLECTION_FEE, "Insufficient deployment+collection fee");
        require(_royaltyFee <= 10000, "Royalty > 100%");

        // Deploy new collection
        NFTCollection newCollection = new NFTCollection(
            _name,
            _symbol,
            _baseURI,
            _royaltyFee,
            _royaltyReceiver,
            msg.sender,  // collection owner
            _mintPrice,
            _maxSupply,
            address(this) // factory address for mint fees
        );

        // Save deployed collection
        deployedCollections.push(address(newCollection));
        emit CollectionDeployed(address(newCollection), msg.sender, _name, _symbol);

        // Refund any extra ETH
        if (msg.value > DEPLOYMENT_FEE + COLLECTION_FEE) {
            payable(msg.sender).transfer(msg.value - (DEPLOYMENT_FEE + COLLECTION_FEE));
        }
    }

    /// @notice Get all deployed collections
    function getDeployedCollections() external view returns (address[] memory) {
        return deployedCollections;
    }

    // ============ Internal Fee Receiver ============
    /// @dev Called by NFTCollection when users mint (for per-NFT platform fees)
    function collectMintFee() external payable {
        // ETH is automatically stored in this contract for later withdrawal
        require(msg.value == NFT_FEE, "Invalid mint fee");
    }
}

/// @title NFT Collection
/// @notice ERC721 with royalty + mint price set by deployer
contract NFTCollection is ERC721, ERC2981, Ownable {
    // ============ State Variables ============
    string private baseURI_;
    uint256 public tokenCounter;
    uint256 public mintPrice;      // Price per NFT (set by deployer)
    uint256 public maxSupply;
    bool public mintEnabled;
    bool public whitelistEnabled;
    address public factory;        // Factory address to send platform fees

    mapping(address => bool) public whitelist;

    // ============ Events ============
    event MintStateUpdated(bool enabled);
    event WhitelistStateUpdated(bool enabled);
    event BaseURIUpdated(string newBaseURI);
    event Withdrawn(address indexed to, uint256 amount);
    event WhitelistUpdated(address indexed account, bool whitelisted);
    event NFTMinted(address indexed minter, uint256 indexed tokenId, uint256 mintPrice);

    // ============ Constructor ============
    constructor(
        string memory _name,
        string memory _symbol,
        string memory initialBaseURI,
        uint96 _royaltyFee,
        address _royaltyReceiver,
        address initialOwner,
        uint256 _mintPrice,
        uint256 _maxSupply,
        address _factory
    ) ERC721(_name, _symbol) Ownable(initialOwner) {
        baseURI_ = initialBaseURI;
        _setDefaultRoyalty(_royaltyReceiver, _royaltyFee);
        mintPrice = _mintPrice;
        maxSupply = _maxSupply;
        mintEnabled = false;
        whitelistEnabled = false;
        factory = _factory;
    }

    // ============ Mint Functions ============

    /// @notice Mint NFTs (paid by user)
    /// @dev Includes both deployer mint price + platform mint fee
    /// @param amount Number of NFTs to mint
    function mint(uint256 amount) external payable {
        require(mintEnabled, "Minting disabled");
        require(amount > 0, "Must mint at least 1");
        require(tokenCounter + amount <= maxSupply, "Exceeds max supply");

        if (whitelistEnabled) {
            require(whitelist[msg.sender], "Not whitelisted");
        }

        // Total cost = (deployer mint price * amount) + (platform fee * amount)
        uint256 totalUserCost = (mintPrice * amount) + (NFTsCollectionFactory(factory).NFT_FEE() * amount);
        require(msg.value >= totalUserCost, "Insufficient ETH");

        // Pay platform fee to factory
        for (uint256 i = 0; i < amount; i++) {
            (bool success, ) = factory.call{value: NFTsCollectionFactory(factory).NFT_FEE()}(
                abi.encodeWithSignature("collectMintFee()")
            );
            require(success, "Mint fee transfer failed");
        }

        // Mint NFTs to user
        for (uint256 i = 0; i < amount; i++) {
            _safeMint(msg.sender, tokenCounter);
            emit NFTMinted(msg.sender, tokenCounter, mintPrice);
            tokenCounter++;
        }

        // Any remaining ETH after platform fee = deployer revenue
        uint256 deployerShare = address(this).balance;
        if (deployerShare > 0) {
            payable(owner()).transfer(deployerShare);
        }
    }

    /// @notice Owner can mint without paying (giveaways, reserves, etc.)
    function ownerMint(address to, uint256 amount) external onlyOwner {
        require(tokenCounter + amount <= maxSupply, "Exceeds max supply");
        for (uint256 i = 0; i < amount; i++) {
            _safeMint(to, tokenCounter);
            emit NFTMinted(to, tokenCounter, 0);
            tokenCounter++;
        }
    }

    // ============ Admin Controls ============

    function setBaseURI(string memory newURI) external onlyOwner {
        baseURI_ = newURI;
        emit BaseURIUpdated(newURI);
    }

    function toggleMinting(bool enabled) external onlyOwner {
        mintEnabled = enabled;
        emit MintStateUpdated(enabled);
    }

    function toggleWhitelist(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistStateUpdated(enabled);
    }

    function updateWhitelist(address account, bool allowed) external onlyOwner {
        whitelist[account] = allowed;
        emit WhitelistUpdated(account, allowed);
    }

    function setMintPrice(uint256 newPrice) external onlyOwner {
        mintPrice = newPrice;
    }

    // ============ Metadata ============

    function _baseURI() internal view override returns (string memory) {
        return baseURI_;
    }

    // ============ Royalty + ERC721 Support ============

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @title NFT Collection Factory
/// @notice Deploys new NFT collections and manages platform fees
/// @dev Implements timelock for admin functions and batch minting with platform fees
contract NFTsCollectionFactory is Ownable, ReentrancyGuard {
    using Strings for uint256;
    
    // ============ State Variables ============
    address[] public deployedCollections;
    address public treasury;

    // Platform fees (adjustable via timelock)
    uint256 public constant DEPLOYMENT_FEE = 1000 ether;
    uint256 public constant COLLECTION_FEE = 500 ether;
    uint256 public constant NFT_FEE = 50 ether;

    uint256 public customDeploymentFee = DEPLOYMENT_FEE;
    uint256 public customCollectionFee = COLLECTION_FEE;
    uint256 public customNFTFee = NFT_FEE;

    // ============ Timelock Variables ============
    uint256 public constant TIMELOCK_DELAY = 2 days;
    
    struct TimelockProposal {
        uint256 deployFee;
        uint256 collectionFee;
        uint256 nftFee;
        address newTreasury;
        uint8 proposalType; // 1=fees, 2=treasury
        uint256 executeAfter;
        bool executed;
        bool cancelled;
    }
    
    mapping(bytes32 => TimelockProposal) public proposals;

    // ============ Events ============
    event CollectionDeployed(
        address indexed collection,
        address indexed deployer,
        string name,
        string symbol
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TreasuryWithdrawn(address indexed treasury, uint256 amount);
    event FeesUpdated(uint256 deployFee, uint256 collFee, uint256 nftFee);
    event RefundAttempted(address indexed user, uint256 amount, bool success);
    event ProposalCreated(
        bytes32 indexed proposalId,
        uint8 proposalType,
        uint256 executeAfter
    );
    event ProposalExecuted(bytes32 indexed proposalId);
    event ProposalCancelled(bytes32 indexed proposalId);

    // ============ Custom Errors ============
    error InvalidTreasuryAddress();
    error InsufficientFee(uint256 required, uint256 provided);
    error RoyaltyTooHigh(uint96 royalty);
    error ProposalAlreadyExists();
    error InvalidProposalType();
    error ProposalAlreadyExecuted();
    error ProposalAlreadyCancelled();
    error TimelockNotExpired(uint256 currentTime, uint256 executeAfter);
    error NoFundsAvailable();
    error WithdrawFailed();
    error NotAuthorized();
    error InvalidMintFee(uint256 expected, uint256 provided);

    // ============ Constructor ============
    constructor(address _initialTreasury) Ownable(msg.sender) {
        if (_initialTreasury == address(0)) revert InvalidTreasuryAddress();
        treasury = _initialTreasury;
        emit TreasuryUpdated(address(0), _initialTreasury);
    }

    // ============ Timelock Functions ============
    
    /// @notice Propose fee changes (requires 2-day delay)
    /// @param _deployFee New deployment fee
    /// @param _collFee New collection fee
    /// @param _nftFee New NFT mint fee
    /// @return proposalId The unique identifier for this proposal
    function proposeFeeChange(
        uint256 _deployFee,
        uint256 _collFee,
        uint256 _nftFee
    ) external onlyOwner returns (bytes32) {
        bytes32 proposalId = keccak256(
            abi.encode(_deployFee, _collFee, _nftFee, block.timestamp)
        );
        if (proposals[proposalId].executeAfter != 0) revert ProposalAlreadyExists();
        
        proposals[proposalId] = TimelockProposal({
            deployFee: _deployFee,
            collectionFee: _collFee,
            nftFee: _nftFee,
            newTreasury: address(0),
            proposalType: 1,
            executeAfter: block.timestamp + TIMELOCK_DELAY,
            executed: false,
            cancelled: false
        });
        
        emit ProposalCreated(proposalId, 1, block.timestamp + TIMELOCK_DELAY);
        return proposalId;
    }
    
    /// @notice Execute fee change after timelock expires
    /// @param proposalId The proposal to execute
    function executeFeeChange(bytes32 proposalId) external onlyOwner {
        TimelockProposal storage proposal = proposals[proposalId];
        
        if (proposal.proposalType != 1) revert InvalidProposalType();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.cancelled) revert ProposalAlreadyCancelled();
        if (block.timestamp < proposal.executeAfter) {
            revert TimelockNotExpired(block.timestamp, proposal.executeAfter);
        }
        
        proposal.executed = true;
        customDeploymentFee = proposal.deployFee;
        customCollectionFee = proposal.collectionFee;
        customNFTFee = proposal.nftFee;
        
        emit ProposalExecuted(proposalId);
        emit FeesUpdated(proposal.deployFee, proposal.collectionFee, proposal.nftFee);
    }
    
    /// @notice Propose treasury change (requires 2-day delay)
    /// @param _treasury New treasury address
    /// @return proposalId The unique identifier for this proposal
    function proposeTreasuryChange(address _treasury)
        external
        onlyOwner
        returns (bytes32)
    {
        if (_treasury == address(0)) revert InvalidTreasuryAddress();
        
        bytes32 proposalId = keccak256(abi.encode(_treasury, block.timestamp));
        if (proposals[proposalId].executeAfter != 0) revert ProposalAlreadyExists();
        
        proposals[proposalId] = TimelockProposal({
            deployFee: 0,
            collectionFee: 0,
            nftFee: 0,
            newTreasury: _treasury,
            proposalType: 2,
            executeAfter: block.timestamp + TIMELOCK_DELAY,
            executed: false,
            cancelled: false
        });
        
        emit ProposalCreated(proposalId, 2, block.timestamp + TIMELOCK_DELAY);
        return proposalId;
    }
    
    /// @notice Execute treasury change after timelock expires
    /// @param proposalId The proposal to execute
    function executeTreasuryChange(bytes32 proposalId) external onlyOwner {
        TimelockProposal storage proposal = proposals[proposalId];
        
        if (proposal.proposalType != 2) revert InvalidProposalType();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.cancelled) revert ProposalAlreadyCancelled();
        if (block.timestamp < proposal.executeAfter) {
            revert TimelockNotExpired(block.timestamp, proposal.executeAfter);
        }
        
        proposal.executed = true;
        address oldTreasury = treasury;
        treasury = proposal.newTreasury;
        
        emit ProposalExecuted(proposalId);
        emit TreasuryUpdated(oldTreasury, proposal.newTreasury);
    }
    
    /// @notice Cancel a pending proposal (emergency only)
    /// @param proposalId The proposal to cancel
    function cancelProposal(bytes32 proposalId) external onlyOwner {
        TimelockProposal storage proposal = proposals[proposalId];
        
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.cancelled) revert ProposalAlreadyCancelled();
        
        proposal.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    /// @notice Withdraw all collected platform fees to treasury
    /// @dev Can be called by owner or treasury address
    function withdrawTreasury() external nonReentrant {
        if (msg.sender != owner() && msg.sender != treasury) {
            revert NotAuthorized();
        }
        
        uint256 balance = address(this).balance;
        if (balance <= 0) revert NoFundsAvailable();
        
        (bool success, ) = payable(treasury).call{value: balance}("");
        if (!success) revert WithdrawFailed();
        
        emit TreasuryWithdrawn(treasury, balance);
    }

    // ============ Collection Deployment ============
    
    /// @notice Deploy a new NFT collection
    /// @param _name Collection name
    /// @param _symbol Collection symbol
    /// @param _baseURI Base URI for token metadata
    /// @param _royaltyFee Royalty fee in basis points (max 10000 = 100%)
    /// @param _royaltyReceiver Address to receive royalties
    /// @param _mintPrice Price per NFT mint
    /// @param _maxSupply Maximum supply of NFTs
    function createCollection(
        string memory _name,
        string memory _symbol,
        string memory _baseURI,
        uint96 _royaltyFee,
        address _royaltyReceiver,
        uint256 _mintPrice,
        uint256 _maxSupply
    ) external payable nonReentrant {
        uint256 requiredFee = customDeploymentFee + customCollectionFee;
        
        if (msg.value < requiredFee) {
            revert InsufficientFee(requiredFee, msg.value);
        }
        if (_royaltyFee > 10000) {
            revert RoyaltyTooHigh(_royaltyFee);
        }

        // Deploy new NFT collection
        NFTCollection newCollection = new NFTCollection(
            _name,
            _symbol,
            _baseURI,
            _royaltyFee,
            _royaltyReceiver,
            msg.sender,
            _mintPrice,
            _maxSupply,
            address(this)
        );

        deployedCollections.push(address(newCollection));
        emit CollectionDeployed(address(newCollection), msg.sender, _name, _symbol);

        // Safe refund (non-reverting)
        if (msg.value > requiredFee) {
            uint256 refundAmount = msg.value - requiredFee;
            (bool refundSuccess, ) = payable(msg.sender).call{value: refundAmount}("");
            emit RefundAttempted(msg.sender, refundAmount, refundSuccess);
        }
    }

    /// @notice Collect batch mint fees from NFT collections
    /// @param _amount Number of NFTs being minted
    function collectMintFees(uint256 _amount) external payable nonReentrant {
        uint256 expectedFee = customNFTFee * _amount;
        if (msg.value != expectedFee) {
            revert InvalidMintFee(expectedFee, msg.value);
        }
        // Fees remain in factory until withdrawn
    }

    /// @notice Get all deployed collections
    /// @return Array of deployed collection addresses
    function getDeployedCollections() external view returns (address[] memory) {
        return deployedCollections;
    }
    
    /// @notice Get the number of deployed collections
    /// @return Number of collections
    function getDeployedCollectionsCount() external view returns (uint256) {
        return deployedCollections.length;
    }
}

// ===============================================================
// ============ NFT Collection Contract ==========================
// ===============================================================

/// @title NFT Collection
/// @notice Individual NFT collection with minting, whitelist, and royalty support
/// @dev Inherits from ERC721, ERC2981, Ownable, and ReentrancyGuard
contract NFTCollection is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using Strings for uint256;
    
    // ============ State Variables ============
    string private baseURI_;
    uint256 public tokenCounter;
    uint256 public mintPrice;
    uint256 public immutable maxSupply;
    bool public mintEnabled;
    bool public whitelistEnabled;
    address public immutable factory;

    uint256 public constant MAX_OWNER_MINT = 20;
    uint256 public constant MAX_MINT_PER_TX = 20;
    uint256 public ownerMintedCount;

    mapping(address => bool) public whitelist;

    // ============ Events ============
    event MintStateUpdated(bool enabled);
    event WhitelistStateUpdated(bool enabled);
    event BaseURIUpdated(string newBaseURI);
    event WhitelistUpdated(address indexed account, bool whitelisted);
    event NFTMinted(address indexed minter, uint256 indexed tokenId, uint256 mintPrice);
    event Withdrawn(address indexed to, uint256 amount);
    event RefundAttempted(address indexed user, uint256 amount, bool success);
    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);

    // ============ Custom Errors ============
    error MintingDisabled();
    error InvalidAmount();
    error ExceedsMaxPerTransaction(uint256 amount, uint256 max);
    error ExceedsMaxSupply(uint256 requested, uint256 available);
    error NotWhitelisted();
    error InsufficientPayment(uint256 required, uint256 provided);
    error PlatformFeeTransferFailed();
    error ExceedsOwnerMintCap(uint256 requested, uint256 remaining);
    error NoBalance();
    error WithdrawFailed();
    error TokenDoesNotExist(uint256 tokenId);

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
        require(_factory != address(0), "Invalid factory");
        baseURI_ = initialBaseURI;
        _setDefaultRoyalty(_royaltyReceiver, _royaltyFee);
        mintPrice = _mintPrice;
        maxSupply = _maxSupply;
        mintEnabled = false;
        whitelistEnabled = false;
        factory = _factory;
    }

    // ============ Minting Functions ============
    
    /// @notice Mint NFTs (paid by user)
    /// @param amount Number of NFTs to mint
    function mint(uint256 amount) external payable nonReentrant {
        if (!mintEnabled) revert MintingDisabled();
        if (amount == 0) revert InvalidAmount();
        if (amount > MAX_MINT_PER_TX) {
            revert ExceedsMaxPerTransaction(amount, MAX_MINT_PER_TX);
        }
        if (tokenCounter + amount > maxSupply) {
            revert ExceedsMaxSupply(amount, maxSupply - tokenCounter);
        }
        if (whitelistEnabled && !whitelist[msg.sender]) {
            revert NotWhitelisted();
        }

        uint256 factoryFee = NFTsCollectionFactory(factory).customNFTFee() * amount;
        uint256 totalUserCost = (mintPrice * amount) + factoryFee;
        
        if (msg.value < totalUserCost) {
            revert InsufficientPayment(totalUserCost, msg.value);
        }

        // Pay platform fee once (batch)
        (bool feeSent, ) = factory.call{value: factoryFee}(
            abi.encodeWithSignature("collectMintFees(uint256)", amount)
        );
        if (!feeSent) revert PlatformFeeTransferFailed();

        // Store starting token ID before minting
        uint256 startTokenId = tokenCounter;
        
        // Mint NFTs
        unchecked {
            for (uint256 i = 0; i < amount; ++i) {
                uint256 currentTokenId = startTokenId + i;
                _safeMint(msg.sender, currentTokenId);
                emit NFTMinted(msg.sender, currentTokenId, mintPrice);
            }
            // Update counter after all mints
            tokenCounter = startTokenId + amount;
        }

        // Optional non-reverting refund for excess ETH
        if (msg.value > totalUserCost) {
            uint256 refundAmount;
            unchecked {
                refundAmount = msg.value - totalUserCost;
            }
            (bool refundSuccess, ) = payable(msg.sender).call{value: refundAmount}("");
            emit RefundAttempted(msg.sender, refundAmount, refundSuccess);
        }
    }

    /// @notice Owner can mint without paying mint or platform fees
    /// @param to Address to mint to
    /// @param amount Number of NFTs to mint
    function ownerMint(address to, uint256 amount) external onlyOwner nonReentrant {
        if (tokenCounter + amount > maxSupply) {
            revert ExceedsMaxSupply(amount, maxSupply - tokenCounter);
        }
        
        uint256 remaining = MAX_OWNER_MINT - ownerMintedCount;
        if (amount > remaining) {
            revert ExceedsOwnerMintCap(amount, remaining);
        }

        // Update counters before minting
        ownerMintedCount += amount;
        uint256 startTokenId = tokenCounter;
        
        unchecked {
            for (uint256 i = 0; i < amount; ++i) {
                uint256 currentTokenId = startTokenId + i;
                _safeMint(to, currentTokenId);
                emit NFTMinted(to, currentTokenId, 0);
            }
            // Update counter after all mints
            tokenCounter = startTokenId + amount;
        }
    }

    /// @notice Withdraw collected funds (creator's revenue)
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance <= 0) revert NoBalance();
        
        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) revert WithdrawFailed();
        
        emit Withdrawn(owner(), balance);
    }

    // ============ Admin Controls ============
    
    /// @notice Set new base URI for token metadata
    /// @param newURI The new base URI
    function setBaseURI(string memory newURI) external onlyOwner {
        baseURI_ = newURI;
        emit BaseURIUpdated(newURI);
    }

    /// @notice Toggle minting on/off
    /// @param enabled Whether minting should be enabled
    function toggleMinting(bool enabled) external onlyOwner {
        mintEnabled = enabled;
        emit MintStateUpdated(enabled);
    }

    /// @notice Toggle whitelist requirement
    /// @param enabled Whether whitelist should be enabled
    function toggleWhitelist(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistStateUpdated(enabled);
    }

    /// @notice Update whitelist status for an address
    /// @param account Address to update
    /// @param allowed Whether the address should be whitelisted
    function updateWhitelist(address account, bool allowed) external onlyOwner {
        whitelist[account] = allowed;
        emit WhitelistUpdated(account, allowed);
    }

    /// @notice Set new mint price
    /// @param newPrice New price per NFT
    function setMintPrice(uint256 newPrice) external onlyOwner {
        uint256 oldPrice = mintPrice;
        mintPrice = newPrice;
        emit MintPriceUpdated(oldPrice, newPrice);
    }

    // ============ Metadata Functions ============
    
    /// @notice Internal base URI getter (used by tokenURI)
    /// @return The base URI string
    function _baseURI() internal view override returns (string memory) {
        return baseURI_;
    }

    /// @notice Public base URI getter for explorers and external tools
    /// @dev This allows blockchain explorers to discover the metadata location
    /// @return The current base URI string
    function baseURI() external view returns (string memory) {
        return baseURI_;
    }

    /// @notice Get the full token URI for a given token ID
    /// @dev Returns baseURI + tokenId + ".json" for proper IPFS metadata resolution
    /// @param tokenId The token ID to get the URI for
    /// @return The complete token URI string
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        if (_ownerOf(tokenId) == address(0)) {
            revert TokenDoesNotExist(tokenId);
        }
        
        string memory base = _baseURI();
        
        // If there's no baseURI, return empty
        if (bytes(base).length == 0) {
            return "";
        }
        
        // Return: baseURI + tokenId + ".json"
        // Example: "ipfs://QmXXX/" + "0" + ".json" = "ipfs://QmXXX/0.json"
        return string(abi.encodePacked(base, tokenId.toString(), ".json"));
    }

    // ============ View Functions ============
    
    /// @notice Get total number of tokens minted
    /// @return The current token counter
    function totalSupply() external view returns (uint256) {
        return tokenCounter;
    }

    // ============ Interface Support ============
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
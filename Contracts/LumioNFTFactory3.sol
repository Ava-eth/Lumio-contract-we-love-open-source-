// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NFT Collection Factory
/// @notice Deploys new NFT collections and manages platform fees
contract NFTsCollectionFactory is Ownable, ReentrancyGuard {
    // ============ State Variables ============
    address[] public deployedCollections;
    address public treasury;

    // ⚠️ M1: PLACEHOLDER FEES - Adjust before production deployment
    // Current values (1000/500/50 ETH) are unrealistic but charged in G 
    // Use setFees() to update values
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
    event CollectionDeployed(address indexed collection, address indexed deployer, string name, string symbol);
    event TreasuryUpdated(address indexed newTreasury);
    event TreasuryWithdrawn(address indexed treasury, uint256 amount);
    event FeesUpdated(uint256 deployFee, uint256 collFee, uint256 nftFee);
    event RefundAttempted(address indexed user, uint256 amount, bool success);
    event ProposalCreated(bytes32 indexed proposalId, uint8 proposalType, uint256 executeAfter);
    event ProposalExecuted(bytes32 indexed proposalId);
    event ProposalCancelled(bytes32 indexed proposalId);

    // ============ Constructor ============
    constructor(address _initialTreasury) Ownable(msg.sender) {
        require(_initialTreasury != address(0), "Invalid treasury");
        treasury = _initialTreasury;
    }

    // ============ Admin Functions ============
    
    // ============ Timelock Functions ============
    
    /// @notice Propose fee changes (requires 2-day delay)
    function proposeFeeChange(
        uint256 _deployFee,
        uint256 _collFee,
        uint256 _nftFee
    ) external onlyOwner returns (bytes32) {
        bytes32 proposalId = keccak256(abi.encode(_deployFee, _collFee, _nftFee, block.timestamp));
        require(proposals[proposalId].executeAfter == 0, "Proposal already exists");
        
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
    function executeFeeChange(bytes32 proposalId) external onlyOwner {
        TimelockProposal storage proposal = proposals[proposalId];
        require(proposal.proposalType == 1, "Not a fee proposal");
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Proposal cancelled");
        require(block.timestamp >= proposal.executeAfter, "Timelock not expired");
        
        proposal.executed = true;
        customDeploymentFee = proposal.deployFee;
        customCollectionFee = proposal.collectionFee;
        customNFTFee = proposal.nftFee;
        
        emit ProposalExecuted(proposalId);
        emit FeesUpdated(proposal.deployFee, proposal.collectionFee, proposal.nftFee);
    }
    
    /// @notice Propose treasury change (requires 2-day delay)
    function proposeTreasuryChange(address _treasury) external onlyOwner returns (bytes32) {
        require(_treasury != address(0), "Invalid address");
        bytes32 proposalId = keccak256(abi.encode(_treasury, block.timestamp));
        require(proposals[proposalId].executeAfter == 0, "Proposal already exists");
        
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
    function executeTreasuryChange(bytes32 proposalId) external onlyOwner {
        TimelockProposal storage proposal = proposals[proposalId];
        require(proposal.proposalType == 2, "Not a treasury proposal");
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Proposal cancelled");
        require(block.timestamp >= proposal.executeAfter, "Timelock not expired");
        
        proposal.executed = true;
        treasury = proposal.newTreasury;
        
        emit ProposalExecuted(proposalId);
        emit TreasuryUpdated(proposal.newTreasury);
    }
    
    /// @notice Cancel a pending proposal (emergency only)
    function cancelProposal(bytes32 proposalId) external onlyOwner {
        TimelockProposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Already cancelled");
        
        proposal.cancelled = true;
        emit ProposalCancelled(proposalId);
    }
    
    // ============ Legacy Admin Functions (DEPRECATED - Use Timelock) ============
    
    /// @notice DEPRECATED: Use proposeTreasuryChange + executeTreasuryChange instead
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @notice DEPRECATED: Use proposeFeeChange + executeFeeChange instead
    function setFees(uint256 _deployFee, uint256 _collFee, uint256 _nftFee) external onlyOwner {
        customDeploymentFee = _deployFee;
        customCollectionFee = _collFee;
        customNFTFee = _nftFee;
        emit FeesUpdated(_deployFee, _collFee, _nftFee);
    }

    /// @notice Withdraw all collected platform fees to treasury
    function withdrawTreasury() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds");
        (bool success, ) = payable(treasury).call{value: balance}("");
        require(success, "Withdraw failed");
        emit TreasuryWithdrawn(treasury, balance);
    }

    // ============ Collection Deployment ============
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
        require(msg.value >= requiredFee, "Insufficient deployment+collection fee");
        require(_royaltyFee <= 10000, "Royalty > 100%");

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
            (bool refundSuccess, ) = msg.sender.call{value: refundAmount}("");
            emit RefundAttempted(msg.sender, refundAmount, refundSuccess);
        }
    }

    /// @notice Collect batch mint fees from NFT collections
    function collectMintFees(uint256 _amount) external payable nonReentrant {
        require(msg.value == customNFTFee * _amount, "Invalid total mint fee");
        // Fees remain in factory until withdrawn
    }

    function getDeployedCollections() external view returns (address[] memory) {
        return deployedCollections;
    }
}

// ===============================================================
// ============ NFT Collection Contract ==========================
// ===============================================================
contract NFTCollection is ERC721, ERC2981, Ownable, ReentrancyGuard {
    string private baseURI_;
    uint256 public tokenCounter;
    uint256 public mintPrice;
    uint256 public maxSupply;
    bool public mintEnabled;
    bool public whitelistEnabled;
    address public factory;

    uint256 public constant MAX_OWNER_MINT = 20;
    uint256 public constant MAX_MINT_PER_TX = 20; // ✅ H4: Prevent gas exhaustion
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
    event MintPriceUpdated(uint256 newPrice); // ✅ L3: Event for mint price changes

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

    /// @notice Mint NFTs (paid by user)
    function mint(uint256 amount) external payable nonReentrant {
        require(mintEnabled, "Minting disabled");
        require(amount > 0, "Must mint at least 1");
        require(amount <= MAX_MINT_PER_TX, "Exceeds max per tx"); // ✅ H4: Prevent gas exhaustion
        require(tokenCounter + amount <= maxSupply, "Exceeds max supply");
        if (whitelistEnabled) require(whitelist[msg.sender], "Not whitelisted");

        uint256 factoryFee = NFTsCollectionFactory(factory).customNFTFee() * amount;
        uint256 totalUserCost = (mintPrice * amount) + factoryFee;
        require(msg.value >= totalUserCost, "Insufficient ETH");

        // Pay platform fee once (batch)
        (bool feeSent, ) = factory.call{value: factoryFee}(
            abi.encodeWithSignature("collectMintFees(uint256)", amount)
        );
        require(feeSent, "Platform fee failed");

        // Mint NFTs
        for (uint256 i = 0; i < amount; i++) {
            _safeMint(msg.sender, tokenCounter);
            emit NFTMinted(msg.sender, tokenCounter, mintPrice);
            tokenCounter++;
        }

        // Optional non-reverting refund for excess ETH
        if (msg.value > totalUserCost) {
            uint256 refundAmount = msg.value - totalUserCost;
            (bool refundSuccess, ) = msg.sender.call{value: refundAmount}("");
            emit RefundAttempted(msg.sender, refundAmount, refundSuccess);
        }
    }

    /// @notice Owner can mint without paying mint or platform fees
    function ownerMint(address to, uint256 amount) external onlyOwner nonReentrant {
        require(tokenCounter + amount <= maxSupply, "Exceeds max supply");
        require(ownerMintedCount + amount <= MAX_OWNER_MINT, "Owner mint cap exceeded");

        ownerMintedCount += amount;
        for (uint256 i = 0; i < amount; i++) {
            _safeMint(to, tokenCounter);
            emit NFTMinted(to, tokenCounter, 0);
            tokenCounter++;
        }
    }

    /// @notice Withdraw collected funds (creator’s revenue)
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdraw failed");
        emit Withdrawn(owner(), balance);
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
        emit MintPriceUpdated(newPrice); // ✅ L3: Emit event for transparency
    }

    // ============ Metadata ============
    function _baseURI() internal view override returns (string memory) {
        return baseURI_;
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

interface IRoyaltyInfo {
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}

interface INFTCollectionFactory {
    function getDeployedCollections() external view returns (address[] memory);
}

contract LumioMarketplace is Ownable, ReentrancyGuard, Pausable, IERC721Receiver {
    // =============================================================
    // 🧩 VARIABLES
    // =============================================================
    address public constant FACTORY_ADDRESS = 0x8fF81e2A79975936ba7856BB09B79C45E2B702C9;
    INFTCollectionFactory public constant factory = INFTCollectionFactory(FACTORY_ADDRESS);

    uint256 public marketplaceFee = 250; // 2.5%
    address public treasury;

    // ✅ Added allowlist tracking for collections
    mapping(address => bool) public allowedCollections;
    
    // ============ Timelock Variables ============
    uint256 public constant TIMELOCK_DELAY = 2 days;
    
    struct TimelockProposal {
        uint256 newFee;
        address newTreasury;
        address collection;
        bool allowStatus;
        uint8 proposalType; // 1=fee, 2=treasury, 3=collection
        uint256 executeAfter;
        bool executed;
        bool cancelled;
    }
    
    mapping(bytes32 => TimelockProposal) public proposals;

    struct Listing {
        address collection;
        uint256 tokenId;
        address payable seller;
        uint256 price;
        bool active;
        bool isPrivate;
        address allowedBuyer;
    }

    struct Auction {
        address collection;
        uint256 tokenId;
        address payable seller;
        uint256 minBid;
        uint256 highestBid;
        address payable highestBidder;
        uint256 endTime;
        bool active;
        bool isPrivate;
        address allowedBidder;
    }

    mapping(address => mapping(uint256 => Listing)) public listings;
    mapping(address => mapping(uint256 => Auction)) public auctions;
    mapping(address => uint256) public pendingWithdrawals;

    // =============================================================
    // 🧩 EVENTS
    // =============================================================
    event NFTApproved(address indexed collection, address indexed owner, uint256 indexed tokenId);
    event NFTListed(address indexed collection, uint256 indexed tokenId, address seller, uint256 price, bool isPrivate);
    event NFTSold(address indexed collection, uint256 indexed tokenId, address buyer, uint256 price);
    event NFTDelisted(address indexed collection, uint256 indexed tokenId);
    event AuctionCreated(address indexed collection, uint256 indexed tokenId, uint256 minBid, uint256 endTime, bool isPrivate);
    event BidPlaced(address indexed collection, uint256 indexed tokenId, address bidder, uint256 bid);
    event AuctionEnded(address indexed collection, uint256 indexed tokenId, address winner, uint256 amount);
    event AuctionCancelled(address indexed collection, uint256 indexed tokenId);
    event Withdrawal(address indexed user, uint256 amount);
    event AdminDustWithdrawn(address indexed to, uint256 amount);
    event CollectionAllowed(address indexed collection, bool allowed);
    event ProposalCreated(bytes32 indexed proposalId, uint8 proposalType, uint256 executeAfter);
    event ProposalExecuted(bytes32 indexed proposalId);
    event ProposalCancelled(bytes32 indexed proposalId);

    // =============================================================
    // ⚙️ CONSTRUCTOR
    // =============================================================
    constructor(address _treasury) Ownable(msg.sender) {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }

    // =============================================================
    // 🧩 APPROVE HANDLER (UI-ONLY)
    // =============================================================
    function approveNFTForMarketplace(address collection, uint256 tokenId) external whenNotPaused {
        emit NFTApproved(collection, msg.sender, tokenId);
        // NOTE: Approval must be done directly from frontend wallet UI using ERC721 approve()
    }

    // =============================================================
    // 🏷️ LISTING FUNCTIONS (ESCROW)
    // =============================================================
    function listNFT(
        address collection,
        uint256 tokenId,
        uint256 price,
        bool isPrivate,
        address allowedBuyer
    ) external nonReentrant whenNotPaused {
        require(price > 0, "Invalid price");
        require(allowedCollections[collection], "Collection not allowed"); // ✅ H3 fix
        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "Not owner");

        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        listings[collection][tokenId] = Listing({
            collection: collection,
            tokenId: tokenId,
            seller: payable(msg.sender),
            price: price,
            active: true,
            isPrivate: isPrivate,
            allowedBuyer: allowedBuyer
        });

        emit NFTListed(collection, tokenId, msg.sender, price, isPrivate);
    }

    function delistNFT(address collection, uint256 tokenId) external nonReentrant {
        Listing storage listing = listings[collection][tokenId];
        require(listing.active, "Not listed");
        require(listing.seller == msg.sender, "Not seller");

        listing.active = false;
        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        emit NFTDelisted(collection, tokenId);

        // ✅ M3: Documented policy – delistNFT is intentionally allowed during pause for safe recovery.
    }

    function buyNFT(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing storage listing = listings[collection][tokenId];
        require(listing.active, "Not for sale");
        require(msg.value >= listing.price, "Insufficient payment");
        require(allowedCollections[collection], "Collection not allowed"); // ✅ verify collection

        if (listing.isPrivate) require(msg.sender == listing.allowedBuyer, "Not allowed buyer");
        listing.active = false;

        // Handle royalties
        uint256 royaltyAmount;
        address royaltyReceiver;
        try IRoyaltyInfo(collection).royaltyInfo(tokenId, listing.price) returns (address receiver, uint256 amount) {
            royaltyReceiver = receiver;
            royaltyAmount = amount;
        } catch {}

        uint256 fee = (listing.price * marketplaceFee) / 10000;
        uint256 sellerProceeds = listing.price - fee - royaltyAmount;

        // Pay marketplace fee & royalties safely
        if (fee > 0) _safeTransferETH(treasury, fee);
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) _safeTransferETH(royaltyReceiver, royaltyAmount);

        // Send NFT to buyer
        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);

        // Pay seller
        _safeTransferETH(listing.seller, sellerProceeds);

        // ✅ C1: Refund overpayment if any
        if (msg.value > listing.price) {
            uint256 excess = msg.value - listing.price;
            _safeTransferETH(msg.sender, excess);
        }

        emit NFTSold(collection, tokenId, msg.sender, listing.price);
    }

    // =============================================================
    // 🕓 AUCTION FUNCTIONS (ESCROW)
    // =============================================================
    function createAuction(
        address collection,
        uint256 tokenId,
        uint256 minBid,
        uint256 duration,
        bool isPrivate,
        address allowedBidder
    ) external nonReentrant whenNotPaused {
        require(allowedCollections[collection], "Collection not allowed");
        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "Not owner");
        require(minBid > 0, "Invalid bid");
        uint256 endTime = block.timestamp + duration;

        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        auctions[collection][tokenId] = Auction({
            collection: collection,
            tokenId: tokenId,
            seller: payable(msg.sender),
            minBid: minBid,
            highestBid: 0,
            highestBidder: payable(address(0)),
            endTime: endTime,
            active: true,
            isPrivate: isPrivate,
            allowedBidder: allowedBidder
        });

        emit AuctionCreated(collection, tokenId, minBid, endTime, isPrivate);
    }

    function placeBid(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused {
        Auction storage auction = auctions[collection][tokenId];
        require(auction.active, "No auction");
        require(block.timestamp < auction.endTime, "Ended");
        require(msg.value >= auction.minBid && msg.value > auction.highestBid, "Low bid");

        if (auction.isPrivate) require(msg.sender == auction.allowedBidder, "Not allowed");

        if (auction.highestBidder != address(0)) {
            pendingWithdrawals[auction.highestBidder] += auction.highestBid;
        }

        auction.highestBid = msg.value;
        auction.highestBidder = payable(msg.sender);

        emit BidPlaced(collection, tokenId, msg.sender, msg.value);
    }

    function cancelAuction(address collection, uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[collection][tokenId];
        require(auction.active, "No auction");
        require(auction.seller == msg.sender, "Not seller");
        require(auction.highestBid == 0, "Already has bid");

        auction.active = false;
        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        emit AuctionCancelled(collection, tokenId);
    }

    // ✅ M4: endAuction allowed even if paused (fail-safe)
    function endAuction(address collection, uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[collection][tokenId];
        require(auction.active, "No auction");
        require(block.timestamp >= auction.endTime, "Not ended yet");

        auction.active = false;

        if (auction.highestBidder == address(0)) {
            IERC721(collection).safeTransferFrom(address(this), auction.seller, tokenId);
            emit AuctionEnded(collection, tokenId, address(0), 0);
            return;
        }

        uint256 royaltyAmount;
        address royaltyReceiver;
        try IRoyaltyInfo(collection).royaltyInfo(tokenId, auction.highestBid) returns (address receiver, uint256 amount) {
            royaltyReceiver = receiver;
            royaltyAmount = amount;
        } catch {}

        uint256 fee = (auction.highestBid * marketplaceFee) / 10000;
        uint256 sellerProceeds = auction.highestBid - fee - royaltyAmount;

        if (fee > 0) _safeTransferETH(treasury, fee);
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) _safeTransferETH(royaltyReceiver, royaltyAmount);
        _safeTransferETH(auction.seller, sellerProceeds);

        IERC721(collection).safeTransferFrom(address(this), auction.highestBidder, tokenId);
        emit AuctionEnded(collection, tokenId, auction.highestBidder, auction.highestBid);
    }

    // =============================================================
    // 💰 WITHDRAWALS
    // =============================================================
    function withdrawPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        _safeTransferETH(msg.sender, amount);
        emit Withdrawal(msg.sender, amount);
    }

    // ✅ M5: Admin dust withdraw
    function withdrawDust(address to) external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No dust");
        _safeTransferETH(to, balance);
        emit AdminDustWithdrawn(to, balance);
    }

    // =============================================================
    // 🧭 QUERY HELPERS
    // =============================================================
    function getFactoryCollections() external view returns (address[] memory) {
        return factory.getDeployedCollections();
    }
    
    /// @notice Get the token URI for a specific NFT from its collection
    /// @param collection The NFT collection address
    /// @param tokenId The token ID
    /// @return The token URI string (returns empty string if not supported)
    function getTokenURI(address collection, uint256 tokenId) external view returns (string memory) {
        try IERC721Metadata(collection).tokenURI(tokenId) returns (string memory uri) {
            return uri;
        } catch {
            return "";
        }
    }
    
    /// @notice Get listing details with token URI
    /// @param collection The NFT collection address
    /// @param tokenId The token ID
    /// @return listing The listing details
    /// @return tokenURI The token metadata URI
    function getListingWithURI(address collection, uint256 tokenId) 
        external 
        view 
        returns (Listing memory listing, string memory tokenURI) 
    {
        listing = listings[collection][tokenId];
        try IERC721Metadata(collection).tokenURI(tokenId) returns (string memory uri) {
            tokenURI = uri;
        } catch {
            tokenURI = "";
        }
    }
    
    /// @notice Get auction details with token URI
    /// @param collection The NFT collection address
    /// @param tokenId The token ID
    /// @return auction The auction details
    /// @return tokenURI The token metadata URI
    function getAuctionWithURI(address collection, uint256 tokenId) 
        external 
        view 
        returns (Auction memory auction, string memory tokenURI) 
    {
        auction = auctions[collection][tokenId];
        try IERC721Metadata(collection).tokenURI(tokenId) returns (string memory uri) {
            tokenURI = uri;
        } catch {
            tokenURI = "";
        }
    }
    
    /// @notice Get collection name and symbol
    /// @param collection The NFT collection address
    /// @return name The collection name
    /// @return symbol The collection symbol
    function getCollectionInfo(address collection) 
        external 
        view 
        returns (string memory name, string memory symbol) 
    {
        try IERC721Metadata(collection).name() returns (string memory _name) {
            name = _name;
        } catch {
            name = "";
        }
        
        try IERC721Metadata(collection).symbol() returns (string memory _symbol) {
            symbol = _symbol;
        } catch {
            symbol = "";
        }
    }

    // =============================================================
    // 🧮 INTERNAL UTILITIES
    // =============================================================
    function _safeTransferETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, ) = payable(to).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    // =============================================================
    // 🛠️ ADMIN FUNCTIONS
    // =============================================================
    
    // ============ Timelock Functions ============
    
    /// @notice Propose marketplace fee change (requires 2-day delay)
    function proposeFeeChange(uint256 newFee) external onlyOwner returns (bytes32) {
        require(newFee <= 1000, "Max 10%");
        bytes32 proposalId = keccak256(abi.encode(newFee, block.timestamp, "fee"));
        require(proposals[proposalId].executeAfter == 0, "Proposal already exists");
        
        proposals[proposalId] = TimelockProposal({
            newFee: newFee,
            newTreasury: address(0),
            collection: address(0),
            allowStatus: false,
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
        marketplaceFee = proposal.newFee;
        
        emit ProposalExecuted(proposalId);
    }
    
    /// @notice Propose treasury change (requires 2-day delay)
    function proposeTreasuryChange(address newTreasury) external onlyOwner returns (bytes32) {
        require(newTreasury != address(0), "Invalid");
        bytes32 proposalId = keccak256(abi.encode(newTreasury, block.timestamp, "treasury"));
        require(proposals[proposalId].executeAfter == 0, "Proposal already exists");
        
        proposals[proposalId] = TimelockProposal({
            newFee: 0,
            newTreasury: newTreasury,
            collection: address(0),
            allowStatus: false,
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
    }
    
    /// @notice Propose collection allowlist change (requires 2-day delay)
    function proposeCollectionAllowlistChange(address collection, bool allowed) external onlyOwner returns (bytes32) {
        bytes32 proposalId = keccak256(abi.encode(collection, allowed, block.timestamp));
        require(proposals[proposalId].executeAfter == 0, "Proposal already exists");
        
        proposals[proposalId] = TimelockProposal({
            newFee: 0,
            newTreasury: address(0),
            collection: collection,
            allowStatus: allowed,
            proposalType: 3,
            executeAfter: block.timestamp + TIMELOCK_DELAY,
            executed: false,
            cancelled: false
        });
        
        emit ProposalCreated(proposalId, 3, block.timestamp + TIMELOCK_DELAY);
        return proposalId;
    }
    
    /// @notice Execute collection allowlist change after timelock expires
    function executeCollectionAllowlistChange(bytes32 proposalId) external onlyOwner {
        TimelockProposal storage proposal = proposals[proposalId];
        require(proposal.proposalType == 3, "Not a collection proposal");
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Proposal cancelled");
        require(block.timestamp >= proposal.executeAfter, "Timelock not expired");
        
        proposal.executed = true;
        allowedCollections[proposal.collection] = proposal.allowStatus;
        
        emit ProposalExecuted(proposalId);
        emit CollectionAllowed(proposal.collection, proposal.allowStatus);
    }
    
    /// @notice Cancel a pending proposal (emergency only)
    function cancelProposal(bytes32 proposalId) external onlyOwner {
        TimelockProposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Already cancelled");
        
        proposal.cancelled = true;
        emit ProposalCancelled(proposalId);
    }
    
    // ============ Emergency Pause Functions ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // =============================================================
    // 🔄 ERC721 RECEIVER
    // =============================================================
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

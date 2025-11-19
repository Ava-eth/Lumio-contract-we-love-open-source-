// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IRoyaltyInfo {
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}

interface INFTCollectionFactory {
    function getDeployedCollections() external view returns (address[] memory);
}

/// @title Lumio Marketplace V2
/// @notice NFT marketplace with listings, auctions, offers, and royalty splitting
/// @dev Implements escrow pattern with reentrancy protection
contract LumioMarketplace is Ownable, ReentrancyGuard, Pausable, IERC721Receiver {
    // =============================================================
    // STATE VARIABLES
    // =============================================================
    address public constant FACTORY_ADDRESS = 0x7Eb9E8EFc71A798B9526903A6d583AB1559B86d2;
    INFTCollectionFactory public immutable factory = INFTCollectionFactory(FACTORY_ADDRESS);

    uint256 public marketplaceFee = 250; // 2.5% in basis points
    address public treasury;

    mapping(address => bool) public allowedCollections;

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

    struct RoyaltySplit {
        address[] recipients;
        uint256[] shares; // Basis points (total must equal 10000)
    }

    struct Offer {
        address collection;
        uint256 tokenId;
        address offeror;
        uint256 offerPrice;
        uint256 expiryTime;
        bool active;
    }

    struct CollectionOffer {
        address collection;
        address offeror;
        uint256 offerPrice;
        uint256 quantity;
        uint256 expiryTime;
        bool active;
    }

    mapping(address => mapping(uint256 => Listing)) public listings;
    mapping(address => mapping(uint256 => Auction)) public auctions;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(address => mapping(uint256 => RoyaltySplit)) private royaltySplits;
    mapping(address => mapping(uint256 => Offer[])) private offers;
    mapping(address => CollectionOffer[]) private collectionOffers;
    mapping(address => mapping(uint256 => uint256)) public offerCount;
    
    // ✅ FIX: Track original owners for listed/auctioned NFTs
    mapping(address => mapping(uint256 => address)) public originalOwners;

    // =============================================================
    // EVENTS
    // =============================================================
    event NFTApproved(address indexed collection, address indexed owner, uint256 indexed tokenId);
    event NFTListed(address indexed collection, uint256 indexed tokenId, address seller, uint256 price, bool isPrivate);
    event NFTSold(address indexed collection, uint256 indexed tokenId, address indexed buyer, address seller, uint256 price);
    event NFTDelisted(address indexed collection, uint256 indexed tokenId);
    event AuctionCreated(address indexed collection, uint256 indexed tokenId, uint256 minBid, uint256 endTime, bool isPrivate);
    event BidPlaced(address indexed collection, uint256 indexed tokenId, address indexed bidder, uint256 bid);
    event AuctionEnded(address indexed collection, uint256 indexed tokenId, address indexed winner, uint256 amount);
    event AuctionCancelled(address indexed collection, uint256 indexed tokenId);
    event Withdrawal(address indexed user, uint256 amount);
    event AdminDustWithdrawn(address indexed to, uint256 amount);
    event CollectionAllowed(address indexed collection, bool allowed);
    event RoyaltySplitConfigured(address indexed collection, uint256 indexed tokenId, address[] recipients, uint256[] shares);
    event RoyaltyDistributed(address indexed collection, uint256 indexed tokenId, address indexed recipient, uint256 amount);
    event OfferMade(address indexed collection, uint256 indexed tokenId, address indexed offeror, uint256 amount, uint256 expiryTime);
    event OfferAccepted(address indexed collection, uint256 indexed tokenId, address indexed seller, address buyer, uint256 amount);
    event OfferCancelled(address indexed collection, uint256 indexed tokenId, address indexed offeror);
    event CollectionOfferMade(address indexed collection, address indexed offeror, uint256 price, uint256 quantity, uint256 expiryTime);
    event CollectionOfferAccepted(address indexed collection, uint256 indexed tokenId, address indexed seller, address buyer, uint256 price);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // =============================================================
    // CUSTOM ERRORS
    // =============================================================
    error InvalidPrice();
    error CollectionNotAllowed();
    error NotTokenOwner();
    error NotListed();
    error NotSeller();
    error NotForSale();
    error InsufficientPayment();
    error NotAllowedBuyer();
    error InvalidBid();
    error NoActiveAuction();
    error AuctionStillActive();
    error AuctionNotEnded();
    error BidsExist();
    error NotAllowedBidder();
    error NothingToWithdraw();
    error InvalidFee();
    error InvalidAddress();
    error OfferMustHaveValue();
    error InvalidDuration();
    error OfferNotActive();
    error OfferExpired();
    error NotYourOffer();
    error InvalidQuantity();
    error NoQuantityLeft();
    error LengthMismatch();
    error NoRecipients();
    error InvalidRecipient();
    error InvalidShare();
    error SharesMustEqual10000();
    error ETHTransferFailed();

    // =============================================================
    // CONSTRUCTOR
    // =============================================================
    constructor(address _treasury) Ownable(msg.sender) {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    // =============================================================
    // LISTING FUNCTIONS (ESCROW)
    // =============================================================
    
    function listNFT(
        address collection,
        uint256 tokenId,
        uint256 price,
        bool isPrivate,
        address allowedBuyer
    ) external nonReentrant whenNotPaused {
        if (price == 0) revert InvalidPrice();
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        
        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        // Store original owner before transfer
        originalOwners[collection][tokenId] = msg.sender;

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
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function delistNFT(address collection, uint256 tokenId) external nonReentrant {
        Listing storage listing = listings[collection][tokenId];
        if (!listing.active) revert NotListed();
        if (listing.seller != msg.sender) revert NotSeller();

        listing.active = false;
        delete originalOwners[collection][tokenId];
        
        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        emit NFTDelisted(collection, tokenId);
    }

    function buyNFT(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing storage listing = listings[collection][tokenId];
        if (!listing.active) revert NotForSale();
        if (msg.value < listing.price) revert InsufficientPayment();
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (listing.isPrivate && msg.sender != listing.allowedBuyer) revert NotAllowedBuyer();

        listing.active = false;
        delete originalOwners[collection][tokenId];

        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);
        
        try IRoyaltyInfo(collection).royaltyInfo(tokenId, listing.price) returns (address receiver, uint256 amount) {
            royaltyReceiver = receiver;
            royaltyAmount = amount;
        } catch {}

        uint256 fee = (listing.price * marketplaceFee) / 10000;
        uint256 sellerProceeds = listing.price - fee - royaltyAmount;

        if (fee > 0) _safeTransferETH(treasury, fee);
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            _safeTransferETH(royaltyReceiver, royaltyAmount);
        }

        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        _safeTransferETH(listing.seller, sellerProceeds);

        if (msg.value > listing.price) {
            _safeTransferETH(msg.sender, msg.value - listing.price);
        }

        emit NFTSold(collection, tokenId, msg.sender, listing.seller, listing.price);
    }

    // =============================================================
    // AUCTION FUNCTIONS (ESCROW)
    // =============================================================
    
    function createAuction(
        address collection,
        uint256 tokenId,
        uint256 minBid,
        uint256 duration,
        bool isPrivate,
        address allowedBidder
    ) external nonReentrant whenNotPaused {
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (minBid == 0) revert InvalidBid();
        
        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        uint256 endTime = block.timestamp + duration;
        originalOwners[collection][tokenId] = msg.sender;

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
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function placeBid(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused {
        Auction storage auction = auctions[collection][tokenId];
        if (!auction.active) revert NoActiveAuction();
        if (block.timestamp >= auction.endTime) revert AuctionStillActive();
        if (msg.value < auction.minBid || msg.value <= auction.highestBid) revert InvalidBid();
        if (auction.isPrivate && msg.sender != auction.allowedBidder) revert NotAllowedBidder();

        if (auction.highestBidder != address(0)) {
            pendingWithdrawals[auction.highestBidder] += auction.highestBid;
        }

        auction.highestBid = msg.value;
        auction.highestBidder = payable(msg.sender);

        emit BidPlaced(collection, tokenId, msg.sender, msg.value);
    }

    function cancelAuction(address collection, uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[collection][tokenId];
        if (!auction.active) revert NoActiveAuction();
        if (auction.seller != msg.sender) revert NotSeller();
        if (auction.highestBid > 0) revert BidsExist();

        auction.active = false;
        delete originalOwners[collection][tokenId];
        
        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        emit AuctionCancelled(collection, tokenId);
    }

    function endAuction(address collection, uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[collection][tokenId];
        if (!auction.active) revert NoActiveAuction();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();

        auction.active = false;
        delete originalOwners[collection][tokenId];

        if (auction.highestBidder == address(0)) {
            IERC721(collection).safeTransferFrom(address(this), auction.seller, tokenId);
            emit AuctionEnded(collection, tokenId, address(0), 0);
            return;
        }

        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);
        
        try IRoyaltyInfo(collection).royaltyInfo(tokenId, auction.highestBid) returns (address receiver, uint256 amount) {
            royaltyReceiver = receiver;
            royaltyAmount = amount;
        } catch {}

        uint256 fee = (auction.highestBid * marketplaceFee) / 10000;
        uint256 sellerProceeds = auction.highestBid - fee - royaltyAmount;

        if (fee > 0) _safeTransferETH(treasury, fee);
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            _safeTransferETH(royaltyReceiver, royaltyAmount);
        }
        
        _safeTransferETH(auction.seller, sellerProceeds);
        IERC721(collection).safeTransferFrom(address(this), auction.highestBidder, tokenId);
        
        emit AuctionEnded(collection, tokenId, auction.highestBidder, auction.highestBid);
    }

    // =============================================================
    // OFFERS SYSTEM (FIXED)
    // =============================================================
    
    /// @notice Make an offer on a specific NFT
    /// @dev Escrows the offer amount until accepted or cancelled
    function makeOffer(
        address collection,
        uint256 tokenId,
        uint256 duration
    ) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert OfferMustHaveValue();
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (duration == 0) revert InvalidDuration();
        
        uint256 expiryTime = block.timestamp + duration;
        
        offers[collection][tokenId].push(Offer({
            collection: collection,
            tokenId: tokenId,
            offeror: msg.sender,
            offerPrice: msg.value,
            expiryTime: expiryTime,
            active: true
        }));
        
        unchecked {
            offerCount[collection][tokenId]++;
        }
        
        emit OfferMade(collection, tokenId, msg.sender, msg.value, expiryTime);
    }
    
    /// @notice Accept an offer on your NFT
    /// @dev Works for both listed and unlisted NFTs
    function acceptOffer(
        address collection,
        uint256 tokenId,
        uint256 offerIndex
    ) external nonReentrant whenNotPaused {
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        
        // Verify ownership and handle escrow cleanup
        address tokenOwner = _verifyOwnershipAndCleanup(collection, tokenId);
        
        // Validate and deactivate offer
        Offer storage offer = offers[collection][tokenId][offerIndex];
        if (!offer.active) revert OfferNotActive();
        if (block.timestamp > offer.expiryTime) revert OfferExpired();
        
        offer.active = false;
        delete originalOwners[collection][tokenId];
        
        // Process sale
        _processOfferSale(
            collection,
            tokenId,
            tokenOwner,
            offer.offeror,
            offer.offerPrice
        );
    }
    
    /// @notice Cancel your own offer and get refund
    function cancelOffer(
        address collection,
        uint256 tokenId,
        uint256 offerIndex
    ) external nonReentrant {
        Offer storage offer = offers[collection][tokenId][offerIndex];
        if (offer.offeror != msg.sender) revert NotYourOffer();
        if (!offer.active) revert OfferNotActive();
        
        offer.active = false;
        _safeTransferETH(msg.sender, offer.offerPrice);
        
        emit OfferCancelled(collection, tokenId, msg.sender);
    }

    // =============================================================
    // COLLECTION OFFERS (FIXED)
    // =============================================================
    
    function makeCollectionOffer(
        address collection,
        uint256 quantity,
        uint256 duration
    ) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert OfferMustHaveValue();
        if (quantity == 0) revert InvalidQuantity();
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (duration == 0) revert InvalidDuration();
        
        uint256 expiryTime = block.timestamp + duration;
        
        collectionOffers[collection].push(CollectionOffer({
            collection: collection,
            offeror: msg.sender,
            offerPrice: msg.value,
            quantity: quantity,
            expiryTime: expiryTime,
            active: true
        }));
        
        emit CollectionOfferMade(collection, msg.sender, msg.value, quantity, expiryTime);
    }
    
    function acceptCollectionOffer(
        address collection,
        uint256 tokenId,
        uint256 offerIndex
    ) external nonReentrant whenNotPaused {
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        
        // Verify ownership and handle escrow cleanup
        address tokenOwner = _verifyOwnershipAndCleanup(collection, tokenId);
        
        // Validate and update offer
        CollectionOffer storage offer = collectionOffers[collection][offerIndex];
        if (!offer.active) revert OfferNotActive();
        if (block.timestamp > offer.expiryTime) revert OfferExpired();
        if (offer.quantity == 0) revert NoQuantityLeft();
        
        unchecked {
            offer.quantity--;
        }
        
        if (offer.quantity == 0) {
            offer.active = false;
        }
        
        delete originalOwners[collection][tokenId];
        
        // Process sale
        _processOfferSale(
            collection,
            tokenId,
            tokenOwner,
            offer.offeror,
            offer.offerPrice
        );
    }
    
    function cancelCollectionOffer(
        address collection,
        uint256 offerIndex
    ) external nonReentrant {
        CollectionOffer storage offer = collectionOffers[collection][offerIndex];
        if (offer.offeror != msg.sender) revert NotYourOffer();
        if (!offer.active) revert OfferNotActive();
        
        offer.active = false;
        _safeTransferETH(msg.sender, offer.offerPrice);
        
        emit OfferCancelled(collection, 0, msg.sender);
    }

    // =============================================================
    // ROYALTY SPLITTING
    // =============================================================
    
    function configureRoyaltySplit(
        address collection,
        uint256 tokenId,
        address[] memory recipients,
        uint256[] memory shares
    ) external {
        // ✅ FIX: Check original owner too
        IERC721 nft = IERC721(collection);
        address tokenOwner = nft.ownerOf(tokenId);
        
        bool isOwner = (tokenOwner == msg.sender) || 
                       (tokenOwner == address(this) && originalOwners[collection][tokenId] == msg.sender);
        
        if (!isOwner) revert NotTokenOwner();
        if (recipients.length != shares.length) revert LengthMismatch();
        if (recipients.length == 0) revert NoRecipients();
        
        uint256 totalShares = 0;
        for (uint256 i = 0; i < shares.length;) {
            if (recipients[i] == address(0)) revert InvalidRecipient();
            if (shares[i] == 0) revert InvalidShare();
            
            unchecked {
                totalShares += shares[i];
                ++i;
            }
        }
        
        if (totalShares != 10000) revert SharesMustEqual10000();
        
        royaltySplits[collection][tokenId] = RoyaltySplit({
            recipients: recipients,
            shares: shares
        });
        
        emit RoyaltySplitConfigured(collection, tokenId, recipients, shares);
    }
    
    function _distributeRoyalties(
        address collection,
        uint256 tokenId,
        uint256 totalRoyaltyAmount
    ) internal {
        RoyaltySplit storage split = royaltySplits[collection][tokenId];
        
        if (split.recipients.length == 0) return;
        
        for (uint256 i = 0; i < split.recipients.length;) {
            uint256 amount = (totalRoyaltyAmount * split.shares[i]) / 10000;
            if (amount > 0) {
                _safeTransferETH(split.recipients[i], amount);
                emit RoyaltyDistributed(collection, tokenId, split.recipients[i], amount);
            }
            
            unchecked {
                ++i;
            }
        }
    }

    // =============================================================
    // WITHDRAWALS
    // =============================================================
    
    function withdrawPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        
        pendingWithdrawals[msg.sender] = 0;
        _safeTransferETH(msg.sender, amount);
        
        emit Withdrawal(msg.sender, amount);
    }

    function withdrawDust(address to) external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance <= 0) revert NothingToWithdraw();
        
        _safeTransferETH(to, balance);
        emit AdminDustWithdrawn(to, balance);
    }

    // =============================================================
    // ADMIN FUNCTIONS
    // =============================================================
    
    function updateFee(uint256 newFee) external onlyOwner {
        if (newFee > 1000) revert InvalidFee();
        
        uint256 oldFee = marketplaceFee;
        marketplaceFee = newFee;
        
        emit FeeUpdated(oldFee, newFee);
    }

    function updateTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        
        address oldTreasury = treasury;
        treasury = newTreasury;
        
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function setCollectionAllowed(address collection, bool allowed) external onlyOwner {
        allowedCollections[collection] = allowed;
        emit CollectionAllowed(collection, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // =============================================================
    // VIEW FUNCTIONS
    // =============================================================
    
    function getFactoryCollections() external view returns (address[] memory) {
        return factory.getDeployedCollections();
    }
    
    function getOffers(address collection, uint256 tokenId) external view returns (Offer[] memory) {
        return offers[collection][tokenId];
    }
    
    function getCollectionOffers(address collection) external view returns (CollectionOffer[] memory) {
        return collectionOffers[collection];
    }
    
    function getRoyaltySplit(address collection, uint256 tokenId) 
        external 
        view 
        returns (address[] memory recipients, uint256[] memory shares) 
    {
        RoyaltySplit storage split = royaltySplits[collection][tokenId];
        return (split.recipients, split.shares);
    }
    
    /// @notice Check if an address can accept an offer (owner or original owner)
    function canAcceptOffer(address collection, uint256 tokenId, address account) 
        external 
        view 
        returns (bool) 
    {
        IERC721 nft = IERC721(collection);
        address tokenOwner = nft.ownerOf(tokenId);
        
        return (tokenOwner == account) || 
               (tokenOwner == address(this) && originalOwners[collection][tokenId] == account);
    }

    // =============================================================
    // INTERNAL UTILITIES
    // =============================================================
    
    /// @notice Verify NFT ownership and cleanup active listings/auctions
    /// @dev Handles both direct ownership and escrowed NFTs
    /// @return tokenOwner The current owner address of the NFT
    function _verifyOwnershipAndCleanup(
        address collection,
        uint256 tokenId
    ) internal returns (address tokenOwner) {
        IERC721 nft = IERC721(collection);
        tokenOwner = nft.ownerOf(tokenId);
        
        bool isOwner = false;
        
        if (tokenOwner == msg.sender) {
            // Direct ownership (NFT not listed)
            isOwner = true;
        } else if (tokenOwner == address(this)) {
            // NFT is in marketplace (listed or auctioned)
            // Check if msg.sender is the original owner
            if (originalOwners[collection][tokenId] == msg.sender) {
                isOwner = true;
                
                // Delist if active
                Listing storage listing = listings[collection][tokenId];
                if (listing.active) {
                    listing.active = false;
                    emit NFTDelisted(collection, tokenId);
                }
                
                // Cancel auction if active
                Auction storage auction = auctions[collection][tokenId];
                if (auction.active) {
                    if (auction.highestBid > 0) {
                        pendingWithdrawals[auction.highestBidder] += auction.highestBid;
                    }
                    auction.active = false;
                    emit AuctionCancelled(collection, tokenId);
                }
            }
        }
        
        if (!isOwner) revert NotTokenOwner();
    }
    
    /// @notice Process offer sale with royalties and fees
    /// @dev Reduces stack depth by extracting payment logic
    function _processOfferSale(
        address collection,
        uint256 tokenId,
        address tokenOwner,
        address buyer,
        uint256 salePrice
    ) internal {
        // Calculate royalties
        uint256 royaltyAmount = _calculateAndPayRoyalties(collection, tokenId, salePrice);
        
        // Calculate fees
        uint256 fee = (salePrice * marketplaceFee) / 10000;
        uint256 sellerProceeds = salePrice - fee - royaltyAmount;
        
        if (fee > 0) _safeTransferETH(treasury, fee);
        
        // Transfer NFT
        IERC721 nft = IERC721(collection);
        if (tokenOwner == address(this)) {
            nft.safeTransferFrom(address(this), buyer, tokenId);
        } else {
            nft.safeTransferFrom(msg.sender, buyer, tokenId);
        }
        
        // Pay seller
        _safeTransferETH(msg.sender, sellerProceeds);
        
        emit OfferAccepted(collection, tokenId, msg.sender, buyer, salePrice);
    }
    
    /// @notice Calculate and distribute royalties
    /// @dev Returns total royalty amount paid
    function _calculateAndPayRoyalties(
        address collection,
        uint256 tokenId,
        uint256 salePrice
    ) internal returns (uint256 royaltyAmount) {
        RoyaltySplit storage split = royaltySplits[collection][tokenId];
        
        if (split.recipients.length > 0) {
            // Use royalty splitting
            try IRoyaltyInfo(collection).royaltyInfo(tokenId, salePrice) returns (address, uint256 amount) {
                royaltyAmount = amount;
                if (royaltyAmount > 0) {
                    _distributeRoyalties(collection, tokenId, royaltyAmount);
                }
            } catch {
                royaltyAmount = 0;
            }
        } else {
            // Standard single royalty receiver
            try IRoyaltyInfo(collection).royaltyInfo(tokenId, salePrice) returns (address receiver, uint256 amount) {
                royaltyAmount = amount;
                if (royaltyAmount > 0 && receiver != address(0)) {
                    _safeTransferETH(receiver, royaltyAmount);
                }
            } catch {
                royaltyAmount = 0;
            }
        }
    }
    
    function _safeTransferETH(address to, uint256 amount) internal {
        if (amount <= 0) return;
        
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./newMarketPlace.sol";

/// @title LumioMarketplaceV2
/// @notice V2 upgrade for Lumio Marketplace with offers, collection offers, and royalty splitting
/// @dev Deploys as separate contract to avoid 24KB size limit. Requires migration from V1.
contract LumioMarketplaceV2 is LumioMarketplace {
    
    // ===== V2: Data Structures =====
    
    /// @notice Royalty split configuration for multi-creator NFTs
    struct RoyaltySplit {
        address[] recipients;
        uint256[] shares;  // Basis points (total must equal 10000)
    }
    
    /// @notice Individual NFT offer
    struct Offer {
        address collection;
        uint256 tokenId;
        address offeror;
        uint256 offerPrice;
        uint256 expiryTime;
        bool active;
    }
    
    /// @notice Collection-wide offer
    struct CollectionOffer {
        address collection;
        address offeror;
        uint256 offerPrice;
        uint256 quantity;
        uint256 expiryTime;
        bool active;
    }
    
    // ===== V2: State Variables =====
    
    mapping(address => mapping(uint256 => RoyaltySplit)) private royaltySplits;
    mapping(address => mapping(uint256 => Offer[])) private offers;
    mapping(address => CollectionOffer[]) private collectionOffers;
    mapping(address => mapping(uint256 => uint256)) public offerCount;
    
    // ===== V2: Events =====
    
    event RoyaltySplitConfigured(
        address indexed collection,
        uint256 indexed tokenId,
        address[] recipients,
        uint256[] shares
    );
    
    event RoyaltyDistributed(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 amount
    );
    
    event OfferMade(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed offeror,
        uint256 offerPrice,
        uint256 expiryTime
    );
    
    event OfferAccepted(
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address offeror,
        uint256 salePrice
    );
    
    event OfferCancelled(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed offeror,
        uint256 offerIndex
    );
    
    event CollectionOfferMade(
        address indexed collection,
        address indexed offeror,
        uint256 offerPrice,
        uint256 quantity,
        uint256 expiryTime
    );
    
    event CollectionOfferAccepted(
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address offeror,
        uint256 salePrice
    );
    
    // ===== Constructor =====
    
    constructor(address _treasury) LumioMarketplace(_treasury) {}
    
    // ===== V2: Royalty Splitting Functions =====
    
    /// @notice Configure royalty split for an NFT
    /// @param collection NFT collection address
    /// @param tokenId Token ID
    /// @param recipients Array of royalty recipient addresses
    /// @param shares Array of shares in basis points (must sum to 10000)
    function configureRoyaltySplit(
        address collection,
        uint256 tokenId,
        address[] memory recipients,
        uint256[] memory shares
    ) external {
        require(IERC721(collection).ownerOf(tokenId) == msg.sender, "Not NFT owner");
        require(recipients.length == shares.length, "Length mismatch");
        require(recipients.length > 0 && recipients.length <= 10, "Invalid recipients count");
        
        uint256 totalShares = 0;
        for (uint256 i = 0; i < shares.length; i++) {
            require(recipients[i] != address(0), "Invalid recipient");
            require(shares[i] > 0, "Share must be > 0");
            totalShares += shares[i];
        }
        require(totalShares == 10000, "Shares must total 10000");
        
        royaltySplits[collection][tokenId] = RoyaltySplit({
            recipients: recipients,
            shares: shares
        });
        
        emit RoyaltySplitConfigured(collection, tokenId, recipients, shares);
    }
    
    /// @notice Internal function to distribute royalties according to split configuration
    /// @param collection NFT collection address
    /// @param tokenId Token ID
    /// @param royaltyAmount Total royalty amount to distribute
    function _distributeRoyalties(
        address collection,
        uint256 tokenId,
        uint256 royaltyAmount
    ) internal {
        RoyaltySplit storage split = royaltySplits[collection][tokenId];
        
        if (split.recipients.length == 0) {
            return; // No split configured
        }
        
        for (uint256 i = 0; i < split.recipients.length; i++) {
            uint256 recipientAmount = (royaltyAmount * split.shares[i]) / 10000;
            _safeTransferETH(split.recipients[i], recipientAmount);
            
            emit RoyaltyDistributed(
                collection,
                tokenId,
                split.recipients[i],
                recipientAmount
            );
        }
    }
    
    // ===== V2: Offer System =====
    
    /// @notice Make an offer on a specific NFT
    /// @param collection NFT collection address
    /// @param tokenId Token ID
    /// @param duration Offer duration in seconds
    function makeOffer(
        address collection,
        uint256 tokenId,
        uint256 duration
    ) external payable nonReentrant {
        require(msg.value > 0, "Offer must have value");
        require(duration > 0 && duration <= 30 days, "Invalid duration");
        
        uint256 expiryTime = block.timestamp + duration;
        
        offers[collection][tokenId].push(Offer({
            collection: collection,
            tokenId: tokenId,
            offeror: msg.sender,
            offerPrice: msg.value,
            expiryTime: expiryTime,
            active: true
        }));
        
        offerCount[collection][tokenId]++;
        
        emit OfferMade(collection, tokenId, msg.sender, msg.value, expiryTime);
    }
    
    /// @notice Accept an offer on your NFT
    /// @param collection NFT collection address
    /// @param tokenId Token ID
    /// @param offerIndex Index of the offer to accept
    function acceptOffer(
        address collection,
        uint256 tokenId,
        uint256 offerIndex
    ) external nonReentrant whenNotPaused {
        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        require(offerIndex < offers[collection][tokenId].length, "Invalid offer");
        
        Offer storage offer = offers[collection][tokenId][offerIndex];
        require(offer.active, "Offer not active");
        require(block.timestamp <= offer.expiryTime, "Offer expired");
        
        address offeror = offer.offeror;
        uint256 salePrice = offer.offerPrice;
        
        // Mark offer as inactive
        offer.active = false;
        
        // Calculate fees
        uint256 marketplaceFeeAmount = (salePrice * marketplaceFee) / 10000;
        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);
        
        // Check for royalty info
        try IRoyaltyInfo(collection).royaltyInfo(tokenId, salePrice) returns (
            address receiver,
            uint256 amount
        ) {
            royaltyReceiver = receiver;
            royaltyAmount = amount;
        } catch {}
        
        // Transfer NFT from seller to buyer
        nft.safeTransferFrom(msg.sender, offeror, tokenId);
        
        // Distribute payments
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            // Check for royalty split
            if (royaltySplits[collection][tokenId].recipients.length > 0) {
                _distributeRoyalties(collection, tokenId, royaltyAmount);
            } else {
                _safeTransferETH(royaltyReceiver, royaltyAmount);
            }
        }
        
        _safeTransferETH(treasury, marketplaceFeeAmount);
        
        uint256 sellerProceeds = salePrice - marketplaceFeeAmount - royaltyAmount;
        _safeTransferETH(msg.sender, sellerProceeds);
        
        emit OfferAccepted(collection, tokenId, msg.sender, offeror, salePrice);
    }
    
    /// @notice Cancel your offer
    /// @param collection NFT collection address
    /// @param tokenId Token ID
    /// @param offerIndex Index of your offer
    function cancelOffer(
        address collection,
        uint256 tokenId,
        uint256 offerIndex
    ) external nonReentrant {
        require(offerIndex < offers[collection][tokenId].length, "Invalid offer");
        
        Offer storage offer = offers[collection][tokenId][offerIndex];
        require(offer.offeror == msg.sender, "Not your offer");
        require(offer.active, "Offer not active");
        
        uint256 refundAmount = offer.offerPrice;
        offer.active = false;
        
        _safeTransferETH(msg.sender, refundAmount);
        
        emit OfferCancelled(collection, tokenId, msg.sender, offerIndex);
    }
    
    // ===== V2: Collection-Wide Offers =====
    
    /// @notice Make an offer for any NFT in a collection
    /// @param collection NFT collection address
    /// @param quantity Number of NFTs willing to buy
    /// @param duration Offer duration in seconds
    function makeCollectionOffer(
        address collection,
        uint256 quantity,
        uint256 duration
    ) external payable nonReentrant {
        require(msg.value > 0, "Offer must have value");
        require(quantity > 0 && quantity <= 100, "Invalid quantity");
        require(duration > 0 && duration <= 30 days, "Invalid duration");
        
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
    
    /// @notice Accept a collection offer with your NFT
    /// @param collection NFT collection address
    /// @param tokenId Your token ID
    /// @param offerIndex Index of the collection offer
    function acceptCollectionOffer(
        address collection,
        uint256 tokenId,
        uint256 offerIndex
    ) external nonReentrant whenNotPaused {
        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        require(offerIndex < collectionOffers[collection].length, "Invalid offer");
        
        CollectionOffer storage offer = collectionOffers[collection][offerIndex];
        require(offer.active, "Offer not active");
        require(block.timestamp <= offer.expiryTime, "Offer expired");
        require(offer.quantity > 0, "Quantity exhausted");
        
        address offeror = offer.offeror;
        uint256 salePrice = offer.offerPrice;
        
        // Update quantity
        offer.quantity--;
        if (offer.quantity == 0) {
            offer.active = false;
        }
        
        // Calculate fees
        uint256 marketplaceFeeAmount = (salePrice * marketplaceFee) / 10000;
        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);
        
        // Check for royalty info
        try IRoyaltyInfo(collection).royaltyInfo(tokenId, salePrice) returns (
            address receiver,
            uint256 amount
        ) {
            royaltyReceiver = receiver;
            royaltyAmount = amount;
        } catch {}
        
        // Transfer NFT from seller to buyer
        nft.safeTransferFrom(msg.sender, offeror, tokenId);
        
        // Distribute payments
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            // Check for royalty split
            if (royaltySplits[collection][tokenId].recipients.length > 0) {
                _distributeRoyalties(collection, tokenId, royaltyAmount);
            } else {
                _safeTransferETH(royaltyReceiver, royaltyAmount);
            }
        }
        
        _safeTransferETH(treasury, marketplaceFeeAmount);
        
        uint256 sellerProceeds = salePrice - marketplaceFeeAmount - royaltyAmount;
        _safeTransferETH(msg.sender, sellerProceeds);
        
        emit CollectionOfferAccepted(collection, tokenId, msg.sender, offeror, salePrice);
    }
    
    /// @notice Cancel your collection offer
    /// @param collection NFT collection address
    /// @param offerIndex Index of your offer
    function cancelCollectionOffer(
        address collection,
        uint256 offerIndex
    ) external nonReentrant {
        require(offerIndex < collectionOffers[collection].length, "Invalid offer");
        
        CollectionOffer storage offer = collectionOffers[collection][offerIndex];
        require(offer.offeror == msg.sender, "Not your offer");
        require(offer.active, "Offer not active");
        
        uint256 refundAmount = offer.offerPrice;
        offer.active = false;
        
        _safeTransferETH(msg.sender, refundAmount);
        
        emit OfferCancelled(collection, 0, msg.sender, offerIndex);
    }
    
    // ===== V2: View Functions =====
    
    /// @notice Get all offers for a specific NFT
    /// @param collection NFT collection address
    /// @param tokenId Token ID
    /// @return Array of offers
    function getOffers(address collection, uint256 tokenId) external view returns (Offer[] memory) {
        return offers[collection][tokenId];
    }
    
    /// @notice Get all collection-wide offers
    /// @param collection NFT collection address
    /// @return Array of collection offers
    function getCollectionOffers(address collection) external view returns (CollectionOffer[] memory) {
        return collectionOffers[collection];
    }
    
    /// @notice Get royalty split configuration for an NFT
    /// @param collection NFT collection address
    /// @param tokenId Token ID
    /// @return recipients Array of royalty recipient addresses
    /// @return shares Array of royalty shares in basis points
    function getRoyaltySplit(address collection, uint256 tokenId) 
        external 
        view 
        returns (address[] memory recipients, uint256[] memory shares) 
    {
        RoyaltySplit storage split = royaltySplits[collection][tokenId];
        return (split.recipients, split.shares);
    }
}

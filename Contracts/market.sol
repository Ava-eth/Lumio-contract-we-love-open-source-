// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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
    address public constant FACTORY_ADDRESS = 0x445C9Eb92Ae7451144C6d32068274fBd8d1d6bcD;
    INFTCollectionFactory public factory = INFTCollectionFactory(FACTORY_ADDRESS);

    uint256 public marketplaceFee = 250; // 2.5%
    address public treasury;

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

    // =============================================================
    // ⚙️ CONSTRUCTOR
    // =============================================================
    constructor(address _treasury) Ownable(msg.sender) {
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
        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "Not owner");

        // Transfer NFT to marketplace escrow
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
    }

    function buyNFT(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing storage listing = listings[collection][tokenId];
        require(listing.active, "Not for sale");
        require(msg.value >= listing.price, "Insufficient payment");

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
        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "Not owner");
        require(minBid > 0, "Invalid bid");
        uint256 endTime = block.timestamp + duration;

        // Transfer NFT to escrow
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

        // Refund previous highest bidder
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

    function endAuction(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        Auction storage auction = auctions[collection][tokenId];
        require(auction.active, "No auction");
        require(block.timestamp >= auction.endTime, "Not ended yet");

        auction.active = false;

        if (auction.highestBidder == address(0)) {
            // No bids — return NFT to seller
            IERC721(collection).safeTransferFrom(address(this), auction.seller, tokenId);
            emit AuctionEnded(collection, tokenId, address(0), 0);
            return;
        }

        // Handle royalty & fees
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

    // =============================================================
    // 🧭 QUERY HELPERS
    // =============================================================
    function getFactoryCollections() external view returns (address[] memory) {
        return factory.getDeployedCollections();
    }

    function getNFTDetails(address collection, uint256 tokenId)
        external
        view
        returns (
            address owner,
            uint256 price,
            bool active,
            string memory metadataURI,
            string memory formattedPrice
        )
    {
        IERC721 nft = IERC721(collection);
        if (listings[collection][tokenId].active) owner = address(this);
        else owner = nft.ownerOf(tokenId);

        price = listings[collection][tokenId].price;
        active = listings[collection][tokenId].active;

        try IERC721Metadata(collection).tokenURI(tokenId) returns (string memory uri) {
            metadataURI = uri;
        } catch {
            metadataURI = "ipfs://QmDefaultLumioLogo";
        }

        formattedPrice = _formatPrice(price);
    }

    // =============================================================
    // 🧮 INTERNAL UTILITIES
    // =============================================================
    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success, ) = payable(to).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function _formatPrice(uint256 weiAmount) internal pure returns (string memory) {
        if (weiAmount == 0) return "0 ETH";
        uint256 ethWhole = weiAmount / 1e18;
        uint256 ethDecimals = (weiAmount % 1e18) / 1e14;

        return string(abi.encodePacked(_uintToString(ethWhole), ".", _uintToString(ethDecimals), " ETH"));
    }

    function _uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        j = v;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + (j % 10)));
            j /= 10;
        }
        return string(bstr);
    }

    // =============================================================
    // 🛠️ ADMIN FUNCTIONS
    // =============================================================
    function updateFee(uint256 newFee) external onlyOwner {
        require(newFee <= 1000, "Max 10%");
        marketplaceFee = newFee;
    }

    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid");
        treasury = newTreasury;
    }

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


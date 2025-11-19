// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title LumioNFTStaking
 * @notice Non-custodial NFT Proof-of-Stake contract.
 *         NFTs remain in the user's wallet; staking is recorded on-chain.
 *         Supports auto-unlock, verified collections, and flexible staking.
 */
contract LumioNFTStaking is Ownable, Pausable {
    // ---------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------
    address public immutable factory; // Immutable factory address
    address public treasury; // Initially factory, can be updated by owner

    uint256 public constant AUTO_UNLOCK_FEE = 2 ether;
    uint256 public constant MAX_NFTS_PER_USER = 1000;

    // ---------------------------------------------------------------------
    // Data Structures
    // ---------------------------------------------------------------------
    struct StakeInfo {
        address collection;
        uint256 tokenId;
        address staker;
        uint256 startTime;
        uint256 unlockTime;
        bool autoUnlock;
        bool active;
    }

    // user => collection => tokenId => stake info
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakes;
    mapping(address => uint256) public userStakeCount;
    mapping(address => bool) public verifiedCollections;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event NFTStaked(address indexed staker, address indexed collection, uint256 indexed tokenId, bool autoUnlock);
    event NFTUnstaked(address indexed staker, address indexed collection, uint256 indexed tokenId);
    event AutoUnlockSet(address indexed staker, address indexed collection, uint256 indexed tokenId, uint256 unlockTime);
    event CollectionVerified(address indexed collection, bool verified);
    event TreasuryUpdated(address indexed newTreasury);
    event Withdrawn(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address _factory) Ownable(msg.sender) {
        require(_factory != address(0), "Invalid factory");
        factory = _factory;
        treasury = _factory;
    }

    // ---------------------------------------------------------------------
    // Admin Functions
    // ---------------------------------------------------------------------

    /**
     * @notice Update treasury address.
     */
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Verify or unverify a collection.
     * @dev Only the factory or contract owner can call this.
     */
    function verifyCollection(address collection, bool status) external {
        require(collection != address(0), "Invalid collection");
        require(msg.sender == factory || msg.sender == owner(), "Not authorized");

        verifiedCollections[collection] = status;
        emit CollectionVerified(collection, status);
    }

    // ---------------------------------------------------------------------
    // User Functions
    // ---------------------------------------------------------------------

    /**
     * @notice Stake NFT (non-custodial). NFT stays in user wallet.
     * @param collection The NFT contract address.
     * @param tokenId The NFT ID.
     * @param lockPeriod Duration until auto-unlock (if enabled).
     * @param enableAutoUnlock Whether to enable auto-unlock.
     */
    function stake(
        address collection,
        uint256 tokenId,
        uint256 lockPeriod,
        bool enableAutoUnlock
    ) external payable whenNotPaused {
        // Checks
        require(verifiedCollections[collection], "Collection not verified");
        require(IERC721(collection).ownerOf(tokenId) == msg.sender, "Not NFT owner");
        require(!stakes[msg.sender][collection][tokenId].active, "Already staked");
        require(userStakeCount[msg.sender] < MAX_NFTS_PER_USER, "Stake limit reached");

        if (enableAutoUnlock) {
            require(msg.value == AUTO_UNLOCK_FEE, "Incorrect auto-unlock fee");
        } else {
            require(msg.value == 0, "No fee required");
        }

        // Effects - Update state BEFORE external calls
        uint256 unlockTime = enableAutoUnlock ? block.timestamp + lockPeriod : 0;

        stakes[msg.sender][collection][tokenId] = StakeInfo({
            collection: collection,
            tokenId: tokenId,
            staker: msg.sender,
            startTime: block.timestamp,
            unlockTime: unlockTime,
            autoUnlock: enableAutoUnlock,
            active: true
        });

        userStakeCount[msg.sender] += 1;

        // Emit events before external calls
        emit NFTStaked(msg.sender, collection, tokenId, enableAutoUnlock);
        if (enableAutoUnlock) emit AutoUnlockSet(msg.sender, collection, tokenId, unlockTime);

        // Interactions - External calls LAST
        if (enableAutoUnlock) {
            (bool sent, ) = payable(treasury).call{value: msg.value}("");
            require(sent, "Fee transfer failed");
        }
    }

    /**
     * @notice Unstake NFT when eligible.
     */
    function unstake(address collection, uint256 tokenId) external whenNotPaused {
        StakeInfo storage info = stakes[msg.sender][collection][tokenId];
        require(info.active, "Not staked");
        require(info.staker == msg.sender, "Not staker");
        require(IERC721(collection).ownerOf(tokenId) == msg.sender, "NFT not in wallet");

        if (info.autoUnlock) {
            require(block.timestamp >= info.unlockTime, "Still locked");
        }

        info.active = false;
        userStakeCount[msg.sender] -= 1;

        emit NFTUnstaked(msg.sender, collection, tokenId);
    }

    // ---------------------------------------------------------------------
    // Owner Controls
    // ---------------------------------------------------------------------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Withdraw any ETH accidentally sent to this contract.
     */
    function withdraw(address payable to) external onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 amount = address(this).balance;
        require(amount > 0, "No funds to withdraw");

        // Emit event before external call
        emit Withdrawn(to, amount);

        (bool success, ) = to.call{value: amount}("");
        require(success, "Withdraw failed");
    }

    receive() external payable {}
}

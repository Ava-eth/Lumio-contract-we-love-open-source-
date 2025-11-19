# LUMIO NFT Marketplace - Smart Contract Documentation

## Overview

The LUMIO NFT Marketplace is a comprehensive Web3 platform deployed on **Gravity Chain (Chain ID: 1625)** that enables users to create, mint, trade, and manage NFT collections with built-in royalties, marketplace functionality, and advanced statistics tracking.

### Network Information

- **Network Name**: Gravity Chain
- **Chain ID**: 1625
- **RPC URL**: `https://rpc.gravity.xyz`
- **Block Explorer**: `https://explorer.gravity.xyz`
- **Currency**: G (Gravity Token)

---

## Core Smart Contracts

### 1. NFT Collection Factory

**Purpose**: Factory contract for deploying ERC-721 NFT collections with royalty support and customizable parameters.

**Contract Address**: `0xB1d1143d1b693b348c3b60936b27F4B24D68D131`

**Key Features**:
- Deploy ERC-721 collections with ERC-2981 royalty standard
- Configurable mint prices, max supply, and royalty fees
- Built-in treasury management for platform fees
- Timelock governance support

#### Deployment Fees

| Fee Type | Amount |
|----------|--------|
| Deployment Fee | 0.01 G |
| Collection Fee | 2% of mint revenue |
| NFT Fee | Configurable per collection |

#### Main Functions

**Create Collection**
```solidity
function createCollection(
    string memory _name,
    string memory _symbol,
    string memory _baseURI,
    uint96 _royaltyFee,          // Basis points (e.g., 500 = 5%)
    address _royaltyReceiver,
    uint256 _mintPrice,          // Price in wei
    uint256 _maxSupply
) external payable
```

**Get All Collections**
```solidity
function getDeployedCollections() external view returns (address[] memory)
```

**Get Collection Count**
```solidity
function getDeployedCollectionsCount() external view returns (uint256)
```

#### Integration Example (JavaScript/TypeScript)

```typescript
import { createPublicClient, createWalletClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

// Contract configuration
const FACTORY_ADDRESS = '0xB1d1143d1b693b348c3b60936b27F4B24D68D131';
const FACTORY_ABI = [...]; // Import from contracts.ts

// Setup client
const account = privateKeyToAccount('0x...');
const walletClient = createWalletClient({
  account,
  chain: gravityChain,
  transport: http()
});

// Create a new NFT collection
const { request } = await publicClient.simulateContract({
  address: FACTORY_ADDRESS,
  abi: FACTORY_ABI,
  functionName: 'createCollection',
  args: [
    'My NFT Collection',
    'MNFT',
    'ipfs://QmYourBaseURI/',
    500,  // 5% royalty
    '0xYourRoyaltyReceiver',
    parseEther('0.01'),  // 0.01 G mint price
    10000  // Max supply
  ],
  value: parseEther('0.01')  // Deployment fee
});

const hash = await walletClient.writeContract(request);
```

---

### 2. Lumio Marketplace (Primary)

**Purpose**: Marketplace contract for trading NFTs from Lumio-deployed collections with listings and auctions.

**Contract Address**: `0x15639Cf7ACbe8dc49B7B8d6595A10dfF2fd3F473`

**Key Features**:
- Fixed-price listings with optional private sales
- Dutch and English auctions
- Automatic royalty distribution (ERC-2981)
- Platform fee collection (2.5%)
- Secure escrow system

#### Marketplace Fees

| Transaction Type | Fee |
|-----------------|-----|
| Listing Fee | 0.001 G |
| Platform Fee | 2.5% of sale price |
| Royalty Fee | Up to 10% (set by collection creator) |

#### Main Functions

**List NFT for Sale**
```solidity
function listNFT(
    address collection,
    uint256 tokenId,
    uint256 price,
    bool isPrivate,
    address allowedBuyer
) external payable
```

**Buy NFT**
```solidity
function buyNFT(
    address collection,
    uint256 tokenId
) external payable
```

**Cancel Listing**
```solidity
function cancelListing(
    address collection,
    uint256 tokenId
) external
```

**Create Auction**
```solidity
function createAuction(
    address collection,
    uint256 tokenId,
    uint256 minBid,
    uint256 duration,
    bool isPrivate,
    address allowedBidder
) external payable
```

**Place Bid**
```solidity
function placeBid(
    address collection,
    uint256 tokenId
) external payable
```

**End Auction**
```solidity
function endAuction(
    address collection,
    uint256 tokenId
) external
```

#### Integration Example (React + Wagmi)

```typescript
import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { parseEther } from 'viem';

// List NFT for sale
function ListNFTComponent() {
  const { writeContract, data: hash } = useWriteContract();
  const { isSuccess } = useWaitForTransactionReceipt({ hash });

  const listNFT = async () => {
    writeContract({
      address: '0x15639Cf7ACbe8dc49B7B8d6595A10dfF2fd3F473',
      abi: MARKETPLACE_ABI,
      functionName: 'listNFT',
      args: [
        '0xYourCollectionAddress',
        1,  // Token ID
        parseEther('1'),  // 1 G price
        false,  // Not private
        '0x0000000000000000000000000000000000000000'
      ],
      value: parseEther('0.001')  // Listing fee
    });
  };

  return (
    <button onClick={listNFT}>
      List NFT for 1 G
    </button>
  );
}
```

---

### 3. The Open Market

**Purpose**: Secondary marketplace for external NFT collections (not deployed via Lumio Factory) with extended trading features.

**Contract Address**: `0x8Aa4264b11dDceb272DE50CE5792D3B299845184`

**Key Features**:
- Support for any ERC-721 or ERC-1155 tokens
- Flexible listing system with expiration times
- Offer/bid system
- Private listings and auctions
- Multi-token support (ERC-20 payment tokens)

#### Marketplace Fees

| Transaction Type | Fee |
|-----------------|-----|
| Listing Fee | 0.001 G |
| Platform Fee | 2.5% of sale price |
| Royalty Fee | Detected from ERC-2981 if available |

#### Main Functions

**Create Listing (ERC-721)**
```solidity
function list(
    address token,
    uint256 tokenId,
    address payToken,
    uint256 pricePerUnit,
    uint256 expiresAt,
    bool isPrivate,
    address allowedBuyer
) external payable
```

**Buy Listed Item**
```solidity
function buy(
    uint256 listId,
    uint256 amount
) external payable
```

**Make Offer**
```solidity
function makeOffer(
    address token,
    uint256 tokenId,
    address payToken,
    uint256 pricePerUnit,
    uint256 expiresAt
) external payable
```

**Accept Offer**
```solidity
function acceptOffer(
    uint256 offerId
) external
```

**Create Auction**
```solidity
function createAuction(
    address token,
    uint256 tokenId,
    address payToken,
    uint256 minBid,
    uint256 reservePrice,
    uint256 duration,
    bool isERC1155,
    uint256 amount
) external payable
```

#### Events

```solidity
event Listed(uint256 indexed listId, address indexed seller, address indexed token, uint256 tokenId, uint256 pricePerUnit);
event Bought(address indexed buyer, address indexed seller, address indexed token, uint256 tokenId, uint256 amount, uint256 price);
event OfferMade(uint256 indexed offerId, address indexed buyer, address indexed token, uint256 tokenId, uint256 pricePerUnit);
event OfferAccepted(uint256 indexed offerId, address indexed seller, address indexed buyer);
event AuctionCreated(uint256 indexed auctionId, address indexed seller, address indexed token, uint256 tokenId);
event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
event AuctionFinalized(uint256 indexed auctionId, address indexed winner, uint256 finalBid);
```

---

### 4. Collection Stats Helper

**Purpose**: Aggregates real-time statistics from Factory collections and both marketplaces to minimize RPC calls.

**Contract Address**: `0x59fa25258B7b45F6aE320a33c9E421A81EeD5444`

**Key Features**:
- Single-call statistics for all collections
- Real-time floor prices from both marketplaces
- Holder count calculations
- Listing and auction counts
- Gas-optimized batch queries

#### Main Functions

**Get All Collection Stats**
```solidity
function getAllCollectionStats() external view returns (CollectionStats[] memory)
```

**Get Single Collection Stats**
```solidity
function getCollectionStats(address collection) external view returns (CollectionStats memory)
```

**Get Collection Listings**
```solidity
function getCollectionListings(address collection) external view returns (ListingData[] memory)
```

**Get Marketplace Stats**
```solidity
function getMarketplaceStats(address collection) external view returns (
    uint256 floorPrice,
    uint256 listedCount,
    uint256 auctionCount
)
```

#### Return Structure

```solidity
struct CollectionStats {
    address collectionAddress;
    string name;
    string symbol;
    address owner;
    uint256 totalSupply;
    uint256 maxSupply;
    uint256 mintPrice;
    string baseURI;
    uint256 totalHolders;
    uint256 floorPrice;        // Lowest price from both marketplaces
    uint256 listedCount;       // Total listings across marketplaces
    uint256 auctionCount;      // Active auctions
}
```

#### Integration Example (React Query)

```typescript
import { useReadContract } from 'wagmi';

function useAllCollectionStats() {
  return useReadContract({
    address: '0x59fa25258B7b45F6aE320a33c9E421A81EeD5444',
    abi: STATS_HELPER_ABI,
    functionName: 'getAllCollectionStats',
    query: {
      refetchInterval: 30000,  // Refresh every 30 seconds
      staleTime: 15000
    }
  });
}

// Usage
function CollectionsList() {
  const { data: stats, isLoading } = useAllCollectionStats();
  
  return (
    <div>
      {stats?.map(collection => (
        <div key={collection.collectionAddress}>
          <h3>{collection.name}</h3>
          <p>Floor: {formatEther(collection.floorPrice)} G</p>
          <p>Listed: {collection.listedCount.toString()}</p>
          <p>Holders: {collection.totalHolders.toString()}</p>
        </div>
      ))}
    </div>
  );
}
```

---

## NFT Collection Contract (ERC-721)

**Purpose**: Individual NFT collection contracts deployed by the Factory.

**Key Features**:
- ERC-721 compliant with metadata extension
- ERC-2981 royalty standard
- Public and whitelist minting
- Configurable mint price and max supply
- Batch minting support

#### Standard Functions

**Mint NFT**
```solidity
function mint(uint256 quantity) external payable
```

**Set Base URI**
```solidity
function setBaseURI(string memory newBaseURI) external
```

**Set Mint Price**
```solidity
function setMintPrice(uint256 newPrice) external
```

**Enable/Disable Minting**
```solidity
function setPublicMintEnabled(bool enabled) external
```

**Whitelist Management**
```solidity
function setWhitelistEnabled(bool enabled) external
function addToWhitelist(address[] memory addresses) external
function removeFromWhitelist(address[] memory addresses) external
```

**Withdraw Funds**
```solidity
function withdraw() external
```

---

## Complete Integration Example

### Full dApp Integration

```typescript
// config/contracts.ts
export const CONTRACTS = {
  factory: {
    address: '0xB1d1143d1b693b348c3b60936b27F4B24D68D131',
    abi: NFT_COLLECTION_FACTORY_ABI
  },
  lumioMarketplace: {
    address: '0x15639Cf7ACbe8dc49B7B8d6595A10dfF2fd3F473',
    abi: MARKETPLACE_ABI
  },
  openMarket: {
    address: '0x8Aa4264b11dDceb272DE50CE5792D3B299845184',
    abi: OPEN_MARKET_ABI
  },
  statsHelper: {
    address: '0x59fa25258B7b45F6aE320a33c9E421A81EeD5444',
    abi: STATS_HELPER_ABI
  }
};

// hooks/useNFTMarketplace.ts
import { useWriteContract, useReadContract } from 'wagmi';
import { parseEther } from 'viem';

export function useNFTMarketplace() {
  const { writeContract } = useWriteContract();

  const listNFT = async (collection: string, tokenId: number, price: string) => {
    return writeContract({
      ...CONTRACTS.lumioMarketplace,
      functionName: 'listNFT',
      args: [collection, tokenId, parseEther(price), false, '0x0'],
      value: parseEther('0.001')
    });
  };

  const buyNFT = async (collection: string, tokenId: number, price: string) => {
    return writeContract({
      ...CONTRACTS.lumioMarketplace,
      functionName: 'buyNFT',
      args: [collection, tokenId],
      value: parseEther(price)
    });
  };

  return { listNFT, buyNFT };
}

// components/CreateCollection.tsx
export function CreateCollection() {
  const { writeContract } = useWriteContract();

  const createCollection = async (params: CollectionParams) => {
    await writeContract({
      ...CONTRACTS.factory,
      functionName: 'createCollection',
      args: [
        params.name,
        params.symbol,
        params.baseURI,
        params.royaltyFee * 100,  // Convert to basis points
        params.royaltyReceiver,
        parseEther(params.mintPrice),
        params.maxSupply
      ],
      value: parseEther('0.01')
    });
  };

  return (/* UI components */);
}
```

---

## Security Considerations

### Access Control
- All contracts implement OpenZeppelin's `Ownable` for admin functions
- Factory uses timelock governance for critical parameter changes
- Marketplace contracts validate NFT ownership before transfers

### Reentrancy Protection
- All state changes occur before external calls
- OpenZeppelin's `ReentrancyGuard` implemented on critical functions

### Fee Validation
- Royalty fees capped at 10% (1000 basis points)
- Platform fees are immutable at deployment
- All fees validated on-chain before execution

---

## Gas Optimization Tips

1. **Batch Operations**: Use `getAllCollectionStats()` instead of multiple individual calls
2. **Event Monitoring**: Listen to contract events instead of polling
3. **Caching**: Cache collection metadata and stats client-side
4. **Multicall**: Use multicall contracts for parallel reads
5. **Efficient Queries**: Use Stats Helper for aggregated data

---

## Contract Verification

All contracts are verified on Gravity Explorer:

- **Factory**: [View on Explorer](https://explorer.gravity.xyz/address/0xB1d1143d1b693b348c3b60936b27F4B24D68D131)
- **Lumio Marketplace**: [View on Explorer](https://explorer.gravity.xyz/address/0x15639Cf7ACbe8dc49B7B8d6595A10dfF2fd3F473)
- **The Open Market**: [View on Explorer](https://explorer.gravity.xyz/address/0x8Aa4264b11dDceb272DE50CE5792D3B299845184)
- **Stats Helper**: [View on Explorer](https://explorer.gravity.xyz/address/0x59fa25258B7b45F6aE320a33c9E421A81EeD5444)

---

## Support & Resources

- **Documentation**: [GitHub Repository](https://github.com/Ava-eth/lumio-gravity-forge)
- **RPC Endpoint**: `https://rpc.gravity.xyz`
- **Explorer**: `https://explorer.gravity.xyz`
- **Chain ID**: 1625

For questions or support, please refer to the project repository or contact the development team.

---

## Changelog

### v1.0.0 (Current)
- Initial deployment of all core contracts
- Factory with timelock governance
- Dual marketplace support (Lumio + Open Market)
- Stats Helper for efficient data aggregation
- Full ERC-721 and ERC-2981 compliance

---

*Last Updated: November 2025*
*Contract Version: 1.0.0*
*Solidity Version: ^0.8.21*

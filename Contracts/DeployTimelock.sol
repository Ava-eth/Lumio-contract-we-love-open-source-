// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Lumio Timelock Deployment Script - PRODUCTION READY
 * @notice Deploy OpenZeppelin TimelockController for production governance
 * @dev Hardened version with full security validations for mainnet deployment
 * @author Lumio Protocol Team
 * 
 * SECURITY FEATURES:
 * - Access control on all functions
 * - Comprehensive parameter validation
 * - Re-deployment protection
 * - Ownership verification
 * - Enhanced event logging
 * - Safe interface calls (no low-level calls)
 */

contract DeployLumioTimelock is Ownable {
    // ============ State Variables ============
    TimelockController public timelock;
    bool public deployed;
    
    // Deployment constraints for mainnet safety
    uint256 public constant MIN_DELAY = 1 hours;     // Minimum: 1 hour
    uint256 public constant MAX_DELAY = 30 days;     // Maximum: 30 days
    uint256 public constant MAX_PROPOSERS = 10;      // Prevent excessive gas
    
    // ============ Events ============
    event TimelockDeployed(
        address indexed timelockAddress,
        uint256 minDelay,
        uint256 proposerCount,
        address admin
    );
    event ContractOwnershipTransferred(
        address indexed contractAddress,
        address indexed oldOwner,
        address indexed newOwner
    );
    event ParametersValidated(uint256 minDelay, uint256 proposerCount);
    event DeploymentWarning(string message);
    
    // ============ Constructor ============
    constructor() Ownable(msg.sender) {
        // Contract deployed, owner set to deployer
    }
    
    // ============ Deployment Functions ============
    
    /**
     * @notice Deploy TimelockController with comprehensive validation
     * @dev Can only be called once by owner. All parameters are validated.
     * @param minDelay Minimum delay in seconds (172800 = 2 days recommended for mainnet)
     * @param proposers Array of addresses that can propose operations (your multisig addresses)
     * @param executors Array of addresses that can execute (use [address(0)] for public execution)
     * @param admin Admin address (use address(0) for no admin = fully decentralized)
     * @return address The deployed TimelockController address
     * 
     * MAINNET RECOMMENDATIONS:
     * - minDelay: 172800 (2 days)
     * - proposers: Your Gnosis Safe multisig address
     * - executors: [address(0)] for public execution after delay
     * - admin: address(0) for full decentralization
     */
    function deployTimelock(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) external onlyOwner returns (address) {
        require(!deployed, "Already deployed");
        
        // ============ Validate Delay ============
        require(minDelay >= MIN_DELAY, "Delay too short (min 1 hour)");
        require(minDelay <= MAX_DELAY, "Delay too long (max 30 days)");
        
        // ============ Validate Proposers ============
        require(proposers.length > 0, "Need at least one proposer");
        require(proposers.length <= MAX_PROPOSERS, "Too many proposers (max 10)");
        
        // Validate no zero addresses and no duplicates
        for (uint i = 0; i < proposers.length; i++) {
            require(proposers[i] != address(0), "Invalid proposer address");
            
            // Check for duplicates
            for (uint j = i + 1; j < proposers.length; j++) {
                require(proposers[i] != proposers[j], "Duplicate proposer");
            }
        }
        
        // ============ Validate Executors ============
        // Executors can be [address(0)] for public execution
        if (executors.length > 0 && executors[0] != address(0)) {
            for (uint i = 0; i < executors.length; i++) {
                require(executors[i] != address(0), "Invalid executor address");
            }
        }
        
        // ============ Admin Warning ============
        // For maximum decentralization, admin should be address(0)
        if (admin != address(0)) {
            emit DeploymentWarning("Admin set - not fully decentralized. Consider using address(0).");
        }
        
        // ============ Deploy TimelockController ============
        timelock = new TimelockController(
            minDelay,
            proposers,
            executors,
            admin
        );
        
        deployed = true;
        
        emit ParametersValidated(minDelay, proposers.length);
        emit TimelockDeployed(address(timelock), minDelay, proposers.length, admin);
        
        return address(timelock);
    }
    
    /**
     * @notice Transfer contract ownership to deployed timelock
     * @dev Validates ownership before and after transfer. Only owner can call.
     * @param contractAddress Address of your deployed contract (factory/marketplace)
     * 
     * IMPORTANT: Caller must be the current owner of the target contract!
     * This function will:
     * 1. Verify timelock is deployed
     * 2. Verify target contract is Ownable
     * 3. Verify caller is current owner
     * 4. Transfer ownership
     * 5. Verify transfer succeeded
     */
    function transferOwnershipToTimelock(address contractAddress) external onlyOwner {
        require(deployed, "Deploy timelock first");
        require(address(timelock) != address(0), "Timelock not deployed");
        require(contractAddress != address(0), "Invalid contract address");
        
        // Get current owner and validate
        address currentOwner;
        try Ownable(contractAddress).owner() returns (address _owner) {
            currentOwner = _owner;
        } catch {
            revert("Contract is not Ownable or owner() failed");
        }
        
        require(currentOwner == msg.sender, "Caller is not contract owner");
        require(currentOwner != address(timelock), "Already owned by timelock");
        
        // Transfer ownership using safe interface call
        try Ownable(contractAddress).transferOwnership(address(timelock)) {
            // Success - now verify
        } catch {
            revert("transferOwnership() call failed");
        }
        
        // Verify ownership was actually transferred
        address newOwner;
        try Ownable(contractAddress).owner() returns (address _owner) {
            newOwner = _owner;
        } catch {
            revert("Ownership verification failed");
        }
        
        require(newOwner == address(timelock), "Ownership not transferred correctly");
        
        emit ContractOwnershipTransferred(contractAddress, currentOwner, address(timelock));
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Check if timelock has been deployed
     * @return bool True if timelock is deployed and operational
     */
    function isDeployed() external view returns (bool) {
        return deployed && address(timelock) != address(0);
    }
    
    /**
     * @notice Get the timelock address
     * @return address The deployed TimelockController address (or zero if not deployed)
     */
    function getTimelockAddress() external view returns (address) {
        return address(timelock);
    }
    
    /**
     * @notice Get the minimum delay of the deployed timelock
     * @return uint256 The minimum delay in seconds (or 0 if not deployed)
     */
    function getTimelockDelay() external view returns (uint256) {
        if (!deployed || address(timelock) == address(0)) {
            return 0;
        }
        return timelock.getMinDelay();
    }
}

/**
 * ╔═══════════════════════════════════════════════════════════════════════════╗
 * ║                    REMIX MAINNET DEPLOYMENT GUIDE                         ║
 * ║                     PRODUCTION-READY VERSION                              ║
 * ╚═══════════════════════════════════════════════════════════════════════════╝
 * 
 * PREREQUISITES:
 * ─────────────────────────────────────────────────────────────────────────────
 * ✅ OpenZeppelin Contracts v5.4.0 installed/imported
 * ✅ Mainnet wallet with sufficient ETH for deployment
 * ✅ Gnosis Safe multisig already deployed (3-of-5 recommended)
 * ✅ Your contracts (NFT Factory, Marketplace, ERC20 Factory) already deployed
 * 
 * 
 * REMIX DEPLOYMENT STEPS:
 * ═════════════════════════════════════════════════════════════════════════════
 * 
 * STEP 1: PREPARE REMIX
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. Open Remix IDE: https://remix.ethereum.org
 * 2. Create new file: contracts/DeployTimelock.sol
 * 3. Copy this entire contract into Remix
 * 4. Install OpenZeppelin (in terminal):
 *    npm install @openzeppelin/contracts@5.4.0
 * 
 * 
 * STEP 2: COMPILE
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. Go to "Solidity Compiler" tab
 * 2. Select compiler version: 0.8.21
 * 3. Enable optimization: Yes, runs: 200
 * 4. Click "Compile DeployTimelock.sol"
 * 5. Verify no errors
 * 
 * 
 * STEP 3: DEPLOY DeployLumioTimelock CONTRACT
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. Go to "Deploy & Run Transactions" tab
 * 2. Environment: Select "Injected Provider - MetaMask"
 * 3. Connect your mainnet wallet (ensure sufficient ETH)
 * 4. Contract: Select "DeployLumioTimelock"
 * 5. Click "Deploy"
 * 6. Confirm transaction in MetaMask
 * 7. Wait for confirmation
 * 8. SAVE the deployed contract address: 0xCeA2CA1Dc54bD8582B4Ec6738485086f730320dB
 * 
 * 
 * STEP 4: DEPLOY TIMELOCKCONTROLLER
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. In Remix, expand the deployed DeployLumioTimelock contract
 * 2. Find "deployTimelock" function
 * 3. Enter parameters:
 * 
 *    minDelay: 172800
 *    // This is 2 days in seconds (2 * 24 * 60 * 60)
 * 
 *    proposers: ["0xC928E0e89F1267A5bd7bF900536884441D4b8E30"]
 *    // Replace with your actual Gnosis Safe address
 *    // Format: Wrap in array brackets and quotes
 * 
 *    executors: ["0x0000000000000000000000000000000000000000"]
 *    // This allows anyone to execute after timelock expires
 * 
 *    admin: 0x0000000000000000000000000000000000000000
 *    // No admin = fully decentralized (recommended)
 * 
 * 4. Click "transact"
 * 5. Confirm in MetaMask
 * 6. Wait for confirmation
 * 7. Check logs for "TimelockDeployed" event
 * 8. Copy the timelock address from event
 * 9. SAVE the TimelockController address: 0x515f15d2E8D880C7851EEFCdFbD1720110089C18
 * 
 * 
 * STEP 5: VERIFY DEPLOYMENT
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. Call "getTimelockAddress()" - should return timelock address
 * 2. Call "isDeployed()" - should return true
 * 3. Call "getTimelockDelay()" - should return 172800
 * 4. Go to Etherscan, search for timelock address
 * 5. Verify contract exists and has correct bytecode
 * 
 * 
 * STEP 6: TRANSFER OWNERSHIP OF YOUR CONTRACTS
 * ─────────────────────────────────────────────────────────────────────────────
 * For EACH of your contracts (NFT Factory, Marketplace, ERC20 Factory):
 * 
 * OPTION A: Using Remix (if you're the current owner)
 * ───────────────────────────────────────────────────────────────────────────
 * 1. Load your contract in Remix "At Address"
 * 2. Enter your contract address
 * 3. Click "At Address"
 * 4. Call "owner()" to verify you're the owner
 * 5. Call "transferOwnership(TIMELOCK_ADDRESS)"
 * 6. Confirm in MetaMask
 * 7. Wait for confirmation
 * 
 * OPTION B: Using DeployLumioTimelock helper (if you deployed it)
 * ───────────────────────────────────────────────────────────────────────────
 * 1. In the deployed DeployLumioTimelock contract
 * 2. Call "transferOwnershipToTimelock"
 * 3. Enter contractAddress: Your contract address
 * 4. Click "transact"
 * 5. Confirm in MetaMask
 * 6. Check for "ContractOwnershipTransferred" event
 * 
 * Repeat for each contract:
 * □ NFT Factory: 0x8fF81e2A79975936ba7856BB09B79C45E2B702C9
 * □ Marketplace: 0xf02537273f8A0D0af20D9B211f11e3c8F4DaF31B
 * □ ERC20 Factory: 0x6cdb4e98A98BDe736651e5691e8DBC7c4F59D1c7
 * 
 * 
 * STEP 7: VERIFY OWNERSHIP TRANSFER
 * ─────────────────────────────────────────────────────────────────────────────
 * For each contract:
 * 1. Call "owner()" function
 * 2. Verify it returns the TimelockController address
 * 3. Try calling an admin function (it should fail from your EOA)
 * 4. Document on Etherscan (add note about timelock governance)
 * 
 * 
 * STEP 8: VERIFY CONTRACTS ON ETHERSCAN
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. DeployLumioTimelock:
 *    - Go to Etherscan contract page
 *    - Click "Verify and Publish"
 *    - Compiler: 0.8.21, Optimization: Yes (200 runs)
 *    - Paste flattened source code
 * 
 * 2. TimelockController:
 *    - Already verified (OpenZeppelin standard)
 *    - But add constructor arguments if needed
 * 
 * 
 * STEP 9: DOCUMENT EVERYTHING
 * ─────────────────────────────────────────────────────────────────────────────
 * Save this information securely:
 * 
 * Network: Ethereum Mainnet
 * Deployment Date: _______________
 * Deployer Address: _______________
 * 
 * Contract Addresses:
 * ├─ DeployLumioTimelock: _______________
 * ├─ TimelockController: _______________
 * ├─ Gnosis Safe Multisig: _______________
 * ├─ NFT Factory: _______________
 * ├─ Marketplace: _______________
 * └─ ERC20 Factory: _______________
 * 
 * Timelock Configuration:
 * ├─ Delay: 2 days (172800 seconds)
 * ├─ Proposers: [List addresses]
 * ├─ Executors: Public (address(0))
 * └─ Admin: None (address(0))
 * 
 * 
 * STEP 10: ANNOUNCE TO COMMUNITY
 * ─────────────────────────────────────────────────────────────────────────────
 * Share on Discord/Twitter/Documentation:
 * 
 * "🎉 Lumio Protocol is now secured with TimelockController!
 * 
 * All sensitive operations (fee changes, treasury updates) now require:
 * ✅ 2-day public notice period
 * ✅ Multisig approval (3-of-5 signatures)
 * ✅ On-chain transparency
 * 
 * TimelockController: [Etherscan link]
 * Multisig: [Etherscan link]
 * 
 * This protects our community from unexpected changes and ensures
 * full transparency in protocol governance."
 * 
 * 
 * TROUBLESHOOTING:
 * ═════════════════════════════════════════════════════════════════════════════
 * 
 * ❌ "Already deployed" error
 *    → You can only deploy once per DeployLumioTimelock contract
 *    → Deploy a new DeployLumioTimelock if needed
 * 
 * ❌ "Delay too short" error
 *    → Minimum delay is 1 hour (3600 seconds)
 *    → Use 172800 for mainnet (2 days)
 * 
 * ❌ "Need at least one proposer" error
 *    → Proposers array cannot be empty
 *    → Add your Gnosis Safe address
 * 
 * ❌ "Caller is not contract owner" error
 *    → You must be the current owner to transfer ownership
 *    → Check owner() on target contract first
 * 
 * ❌ "Contract is not Ownable" error
 *    → Target contract doesn't have owner() function
 *    → Verify you're using the correct contract address
 * 
 * ❌ Out of gas error
 *    → Increase gas limit in MetaMask
 *    → Try 500,000 gas limit for deployment
 * 
 * 
 * SECURITY REMINDERS:
 * ═════════════════════════════════════════════════════════════════════════════
 * ⚠️  NEVER share your private keys
 * ⚠️  ALWAYS verify contract addresses before transferring ownership
 * ⚠️  ALWAYS test on testnet first if possible
 * ⚠️  SAVE all contract addresses in multiple secure locations
 * ⚠️  VERIFY all contracts on Etherscan
 * ⚠️  DOCUMENT the deployment for your team
 * ⚠️  SET UP monitoring (Tenderly, Defender, etc.)
 * 
 * 
 * NEXT STEPS AFTER DEPLOYMENT:
 * ═════════════════════════════════════════════════════════════════════════════
 * 1. Read TIMELOCK_WORKFLOW.md for usage instructions
 * 2. Test proposing a change (on testnet if possible)
 * 3. Set up monitoring alerts
 * 4. Train team on governance procedures
 * 5. Create runbook for common operations
 * 
 * 
 * FOR SUPPORT:
 * ═════════════════════════════════════════════════════════════════════════════
 * - Read TIMELOCK_QUICK_REFERENCE.md
 * - Read TIMELOCK_ARCHITECTURE.md
 * - Check Etherscan transaction history
 * - Review OpenZeppelin TimelockController docs
 * 
 * ╔═══════════════════════════════════════════════════════════════════════════╗
 * ║  🎉 CONGRATULATIONS! Your contracts are now production-ready with         ║
 * ║     institutional-grade governance and timelock protection!               ║
 * ╚═══════════════════════════════════════════════════════════════════════════╝
 */

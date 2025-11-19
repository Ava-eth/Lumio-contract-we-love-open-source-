// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Lumio ERC20 Factory
 * @notice Deploys customizable ERC20 tokens safely
 */
contract LumioERC20Factory is Ownable {
    // ⚠️ M1: PLACEHOLDER FEE - Adjust before production deployment
    // Current value (5000 ETH) is unrealistic and for testing only
    uint256 public constant DEPLOYMENT_FEE = 5000 ether;
    address public treasury;
    address[] public deployedTokens;
    
    // ============ Vesting Structures ============
    struct VestingSchedule {
        address token;           // ERC20 token address
        address beneficiary;     // Who receives the tokens
        uint256 totalAmount;     // Total tokens to vest
        uint256 startTime;       // When vesting starts
        uint256 cliff;           // Cliff period in seconds
        uint256 duration;        // Total vesting duration
        uint256 released;        // Amount already released
        bool revoked;            // Whether vesting was revoked
    }
    
    mapping(uint256 => VestingSchedule) public vestingSchedules;
    mapping(address => uint256[]) public beneficiarySchedules; // Track schedules per beneficiary
    uint256 public vestingScheduleCount;

    event TokenDeployed(address indexed token, address indexed creator, string name, string symbol, uint256 supply);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event FeeRefunded(address indexed to, uint256 amount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event VestingScheduleCreated(
        uint256 indexed scheduleId,
        address indexed token,
        address indexed beneficiary,
        uint256 amount,
        uint256 duration,
        uint256 cliff
    );
    event TokensVested(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event VestingRevoked(uint256 indexed scheduleId, uint256 refundAmount);

    constructor(address _treasury) Ownable(msg.sender) {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }

    /**
     * @notice Deploy a new ERC20 token with selected features
     * @dev Uses safe low-level calls for refunds (H1 & H2 fixes)
     */
    function createToken(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _initialSupply,
        bool _mintable,
        bool _burnable,
        bool _pausable,
        uint256 _maxSupply
    ) external payable {
        require(msg.value >= DEPLOYMENT_FEE, "Insufficient deployment fee");

        // === Deploy Token ===
        CustomERC20 newToken = new CustomERC20(
            _name,
            _symbol,
            _decimals,
            _initialSupply,
            msg.sender,
            _mintable,
            _burnable,
            _pausable,
            _maxSupply
        );

        deployedTokens.push(address(newToken));
        emit TokenDeployed(address(newToken), msg.sender, _name, _symbol, _initialSupply);

        // === Refund any overpayment safely (H1 + H2 fix) ===
        if (msg.value > DEPLOYMENT_FEE) {
            uint256 refundAmount = msg.value - DEPLOYMENT_FEE;
            (bool refundSuccess, ) = payable(msg.sender).call{value: refundAmount}("");
            if (refundSuccess) emit FeeRefunded(msg.sender, refundAmount);
            // Note: we don’t revert on refund failure (prevents DoS)
        }
    }

    /**
     * @notice Withdraw collected deployment fees
     * @dev Can be called by owner (TimelockController) or treasury address directly
     */
    function withdrawTreasury() external {
        require(msg.sender == owner() || msg.sender == treasury, "Not authorized");
        uint256 bal = address(this).balance;
        require(bal > 0, "No funds");

        (bool success, ) = payable(treasury).call{value: bal}("");
        require(success, "ETH transfer failed");

        emit TreasuryWithdrawn(treasury, bal);
    }
    
    /**
     * @notice Update treasury address (requires owner - timelock governance)
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    // ============ Vesting Functions ============
    
    /**
     * @notice Create a vesting schedule for ERC20 tokens
     * @param token Address of the ERC20 token
     * @param beneficiary Address that will receive vested tokens
     * @param amount Total amount of tokens to vest
     * @param cliff Cliff period in seconds (no tokens released before)
     * @param duration Total vesting duration in seconds
     */
    function createVestingSchedule(
        address token,
        address beneficiary,
        uint256 amount,
        uint256 cliff,
        uint256 duration
    ) external returns (uint256) {
        require(token != address(0), "Invalid token");
        require(beneficiary != address(0), "Invalid beneficiary");
        require(amount > 0, "Amount must be > 0");
        require(duration > 0, "Duration must be > 0");
        require(duration >= cliff, "Duration must be >= cliff");
        
        // Transfer tokens to this contract for vesting
        require(
            ERC20(token).transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );
        
        uint256 scheduleId = vestingScheduleCount++;
        
        vestingSchedules[scheduleId] = VestingSchedule({
            token: token,
            beneficiary: beneficiary,
            totalAmount: amount,
            startTime: block.timestamp,
            cliff: cliff,
            duration: duration,
            released: 0,
            revoked: false
        });
        
        beneficiarySchedules[beneficiary].push(scheduleId);
        
        emit VestingScheduleCreated(
            scheduleId,
            token,
            beneficiary,
            amount,
            duration,
            cliff
        );
        
        return scheduleId;
    }
    
    /**
     * @notice Release vested tokens to beneficiary
     * @param scheduleId The vesting schedule ID
     */
    function releaseVestedTokens(uint256 scheduleId) external {
        VestingSchedule storage schedule = vestingSchedules[scheduleId];
        require(schedule.beneficiary != address(0), "Schedule not found");
        require(!schedule.revoked, "Vesting revoked");
        require(msg.sender == schedule.beneficiary, "Not beneficiary");
        
        uint256 releasable = _calculateReleasableAmount(schedule);
        require(releasable > 0, "No tokens to release");
        
        schedule.released += releasable;
        
        require(
            ERC20(schedule.token).transfer(schedule.beneficiary, releasable),
            "Transfer failed"
        );
        
        emit TokensVested(scheduleId, schedule.beneficiary, releasable);
    }
    
    /**
     * @notice Revoke a vesting schedule (only owner)
     * @param scheduleId The vesting schedule ID
     */
    function revokeVesting(uint256 scheduleId) external onlyOwner {
        VestingSchedule storage schedule = vestingSchedules[scheduleId];
        require(schedule.beneficiary != address(0), "Schedule not found");
        require(!schedule.revoked, "Already revoked");
        
        // Calculate what's already vested
        uint256 vested = _calculateReleasableAmount(schedule);
        
        // Release vested amount to beneficiary
        if (vested > 0) {
            schedule.released += vested;
            require(
                ERC20(schedule.token).transfer(schedule.beneficiary, vested),
                "Transfer failed"
            );
        }
        
        // Return unvested tokens to owner
        uint256 unvested = schedule.totalAmount - schedule.released;
        if (unvested > 0) {
            require(
                ERC20(schedule.token).transfer(owner(), unvested),
                "Refund failed"
            );
        }
        
        schedule.revoked = true;
        
        emit VestingRevoked(scheduleId, unvested);
    }
    
    /**
     * @notice Calculate releasable amount for a vesting schedule
     * @param schedule The vesting schedule
     * @return Amount of tokens that can be released
     */
    function _calculateReleasableAmount(VestingSchedule memory schedule) 
        private 
        view 
        returns (uint256) 
    {
        if (block.timestamp < schedule.startTime + schedule.cliff) {
            return 0; // Still in cliff period
        }
        
        uint256 elapsedTime = block.timestamp - schedule.startTime;
        uint256 vestedAmount;
        
        if (elapsedTime >= schedule.duration) {
            // Fully vested
            vestedAmount = schedule.totalAmount;
        } else {
            // Linear vesting
            vestedAmount = (schedule.totalAmount * elapsedTime) / schedule.duration;
        }
        
        return vestedAmount - schedule.released;
    }
    
    /**
     * @notice Get vesting schedule details
     * @param scheduleId The vesting schedule ID
     * @return token Token address
     * @return beneficiary Beneficiary address
     * @return totalAmount Total tokens
     * @return released Released tokens
     * @return releasable Currently releasable tokens
     * @return revoked Whether revoked
     */
    function getVestingSchedule(uint256 scheduleId) 
        external 
        view 
        returns (
            address token,
            address beneficiary,
            uint256 totalAmount,
            uint256 released,
            uint256 releasable,
            bool revoked
        ) 
    {
        VestingSchedule memory schedule = vestingSchedules[scheduleId];
        require(schedule.beneficiary != address(0), "Schedule not found");
        
        return (
            schedule.token,
            schedule.beneficiary,
            schedule.totalAmount,
            schedule.released,
            _calculateReleasableAmount(schedule),
            schedule.revoked
        );
    }
    
    /**
     * @notice Get all vesting schedule IDs for a beneficiary
     * @param beneficiary The beneficiary address
     * @return Array of schedule IDs
     */
    function getBeneficiarySchedules(address beneficiary) 
        external 
        view 
        returns (uint256[] memory) 
    {
        return beneficiarySchedules[beneficiary];
    }

    function getDeployedTokens() external view returns (address[] memory) {
        return deployedTokens;
    }
}

/**
 * @title Customizable ERC20 Token
 * @notice ERC20 with optional mint/burn/pause/cap features
 */
contract CustomERC20 is ERC20, ERC20Burnable, ERC20Pausable, ERC20Capped, Ownable {
    uint8 private immutable customDecimals;
    bool public immutable mintable;
    bool public immutable burnable;
    bool public immutable pausable;

    // ============ V2: Vesting ============
    struct VestingSchedule {
        address beneficiary;
        uint256 totalAmount;
        uint256 startTime;
        uint256 cliff;
        uint256 duration;
        uint256 released;
    }
    
    mapping(address => VestingSchedule[]) public vestingSchedules;
    mapping(address => bool) public hasVesting;
    
    // ============ V2: Token Locking ============
    struct TokenLock {
        uint256 amount;
        uint256 unlockTime;
        bool withdrawn;
    }
    
    mapping(address => TokenLock[]) public locks;
    
    // ============ V2: Governance ============
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 endTime;
        bool executed;
        mapping(address => bool) hasVoted;
    }
    
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant PROPOSAL_THRESHOLD = 1000 * 10**18; // Need 1000 tokens to propose

    event Minted(address indexed to, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);
    
    // V2 Events
    event VestingScheduleCreated(address indexed beneficiary, uint256 amount, uint256 startTime, uint256 cliff, uint256 duration);
    event TokensVested(address indexed beneficiary, uint256 amount);
    event TokensLocked(address indexed holder, uint256 amount, uint256 unlockTime, uint256 lockId);
    event TokensUnlocked(address indexed holder, uint256 amount, uint256 lockId);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 endTime);
    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support, uint256 votes);
    event ProposalExecuted(uint256 indexed proposalId);

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _initialSupply,
        address _owner,
        bool _mintable,
        bool _burnable,
        bool _pausable,
        uint256 _maxSupply
    )
        ERC20(_name, _symbol)
        ERC20Capped(_maxSupply > 0 ? _maxSupply : type(uint256).max)
        Ownable(_owner)
    {
        customDecimals = _decimals;
        mintable = _mintable;
        burnable = _burnable;
        pausable = _pausable;

        // === Scale initial supply by decimals ===
        uint256 scaledSupply = _initialSupply * (10 ** _decimals);
        _mint(_owner, scaledSupply);
    }

    /// @notice Override decimals
    function decimals() public view override returns (uint8) {
        return customDecimals;
    }

    /// @notice Mint new tokens if mintable
    function mint(address to, uint256 amount) external onlyOwner {
        require(mintable, "Minting disabled");
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /// @notice Pause transfers if pausable
    function pause() external onlyOwner {
        require(pausable, "Pause disabled");
        _pause(); // Emits OpenZeppelin's Paused(address)
    }

    /// @notice Unpause transfers if pausable
    function unpause() external onlyOwner {
        require(pausable, "Pause disabled");
        _unpause(); // Emits OpenZeppelin's Unpaused(address)
    }

    /// @notice Withdraw accidentally sent ETH from this token contract
    /// @dev Safe pattern using low-level call to prevent reentrancy
    function withdraw(address payable to) external onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 amount = address(this).balance;
        require(amount > 0, "No funds to withdraw");

        (bool success, ) = to.call{value: amount}("");
        require(success, "Withdraw failed");

        emit Withdrawn(msg.sender, amount);
    }

    // === Overrides ===
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Pausable, ERC20Capped)
    {
        super._update(from, to, amount);
    }

    receive() external payable {} // Accept ETH just in case

    // =============================================================
    // 📅 V2: VESTING SCHEDULES
    // =============================================================
    
    /// @notice Create a vesting schedule for a beneficiary
    /// @param beneficiary Address receiving vested tokens
    /// @param amount Total amount to vest
    /// @param cliff Cliff period in seconds
    /// @param duration Total vesting duration in seconds
    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        uint256 cliff,
        uint256 duration
    ) external onlyOwner {
        require(beneficiary != address(0), "Invalid beneficiary");
        require(amount > 0, "Amount must be > 0");
        require(duration > cliff, "Duration must exceed cliff");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // Transfer tokens to this contract for vesting
        _transfer(msg.sender, address(this), amount);
        
        vestingSchedules[beneficiary].push(VestingSchedule({
            beneficiary: beneficiary,
            totalAmount: amount,
            startTime: block.timestamp,
            cliff: cliff,
            duration: duration,
            released: 0
        }));
        hasVesting[beneficiary] = true;
        
        emit VestingScheduleCreated(beneficiary, amount, block.timestamp, cliff, duration);
    }
    
    /// @notice Release vested tokens
    /// @param scheduleIndex Index of the vesting schedule
    function releaseVestedTokens(uint256 scheduleIndex) external {
        require(scheduleIndex < vestingSchedules[msg.sender].length, "Invalid schedule");
        
        VestingSchedule storage schedule = vestingSchedules[msg.sender][scheduleIndex];
        require(schedule.beneficiary == msg.sender, "Not beneficiary");
        
        uint256 releasable = _calculateReleasableAmount(schedule);
        require(releasable > 0, "No tokens to release");
        
        schedule.released += releasable;
        
        _transfer(address(this), msg.sender, releasable);
        
        emit TokensVested(msg.sender, releasable);
    }
    
    /// @notice Calculate releasable amount for a vesting schedule
    function _calculateReleasableAmount(VestingSchedule memory schedule) 
        private 
        view 
        returns (uint256) 
    {
        if (block.timestamp < schedule.startTime + schedule.cliff) {
            return 0;
        }
        
        uint256 elapsedTime = block.timestamp - schedule.startTime;
        uint256 vestedAmount;
        
        if (elapsedTime >= schedule.duration) {
            vestedAmount = schedule.totalAmount;
        } else {
            vestedAmount = (schedule.totalAmount * elapsedTime) / schedule.duration;
        }
        
        return vestedAmount - schedule.released;
    }
    
    /// @notice Get vesting schedule details
    /// @param beneficiary Address to check
    /// @param scheduleIndex Index of schedule
    function getVestingSchedule(address beneficiary, uint256 scheduleIndex) 
        external 
        view 
        returns (
            uint256 totalAmount,
            uint256 startTime,
            uint256 cliff,
            uint256 duration,
            uint256 released,
            uint256 releasable
        ) 
    {
        require(scheduleIndex < vestingSchedules[beneficiary].length, "Invalid schedule");
        VestingSchedule memory schedule = vestingSchedules[beneficiary][scheduleIndex];
        
        return (
            schedule.totalAmount,
            schedule.startTime,
            schedule.cliff,
            schedule.duration,
            schedule.released,
            _calculateReleasableAmount(schedule)
        );
    }

    // =============================================================
    // 🔒 V2: TOKEN LOCKING
    // =============================================================
    
    /// @notice Lock tokens for a specific period
    /// @param amount Amount to lock
    /// @param duration Lock duration in seconds
    function lockTokens(uint256 amount, uint256 duration) external {
        require(amount > 0, "Amount must be > 0");
        require(duration > 0, "Duration must be > 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        uint256 unlockTime = block.timestamp + duration;
        
        // Transfer tokens to this contract
        _transfer(msg.sender, address(this), amount);
        
        locks[msg.sender].push(TokenLock({
            amount: amount,
            unlockTime: unlockTime,
            withdrawn: false
        }));
        
        uint256 lockId = locks[msg.sender].length - 1;
        
        emit TokensLocked(msg.sender, amount, unlockTime, lockId);
    }
    
    /// @notice Unlock tokens after lock period expires
    /// @param lockId Index of the lock
    function unlockTokens(uint256 lockId) external {
        require(lockId < locks[msg.sender].length, "Invalid lock ID");
        
        TokenLock storage lock = locks[msg.sender][lockId];
        require(!lock.withdrawn, "Already withdrawn");
        require(block.timestamp >= lock.unlockTime, "Still locked");
        
        lock.withdrawn = true;
        
        _transfer(address(this), msg.sender, lock.amount);
        
        emit TokensUnlocked(msg.sender, lock.amount, lockId);
    }
    
    /// @notice Get lock details
    /// @param holder Address to check
    /// @param lockId Index of lock
    function getLock(address holder, uint256 lockId) 
        external 
        view 
        returns (
            uint256 amount,
            uint256 unlockTime,
            bool withdrawn,
            bool canUnlock
        ) 
    {
        require(lockId < locks[holder].length, "Invalid lock ID");
        TokenLock memory lock = locks[holder][lockId];
        
        return (
            lock.amount,
            lock.unlockTime,
            lock.withdrawn,
            block.timestamp >= lock.unlockTime && !lock.withdrawn
        );
    }
    
    /// @notice Get all locks for an address
    /// @param holder Address to check
    function getLocksCount(address holder) external view returns (uint256) {
        return locks[holder].length;
    }

    // =============================================================
    // 🗳️ V2: GOVERNANCE (VOTING)
    // =============================================================
    
    /// @notice Create a governance proposal
    /// @param description Proposal description
    function createProposal(string memory description) external {
        require(balanceOf(msg.sender) >= PROPOSAL_THRESHOLD, "Insufficient tokens to propose");
        require(bytes(description).length > 0, "Empty description");
        
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.description = description;
        proposal.endTime = block.timestamp + VOTING_PERIOD;
        proposal.executed = false;
        
        emit ProposalCreated(proposalId, msg.sender, description, proposal.endTime);
    }
    
    /// @notice Vote on a proposal
    /// @param proposalId ID of the proposal
    /// @param support True for yes, false for no
    function vote(uint256 proposalId, bool support) external {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp <= proposal.endTime, "Voting ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        
        uint256 votes = balanceOf(msg.sender);
        require(votes > 0, "No voting power");
        
        proposal.hasVoted[msg.sender] = true;
        
        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }
        
        emit VoteCast(msg.sender, proposalId, support, votes);
    }
    
    /// @notice Execute a passed proposal (owner only for now)
    /// @param proposalId ID of the proposal
    function executeProposal(uint256 proposalId) external onlyOwner {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp > proposal.endTime, "Voting not ended");
        require(!proposal.executed, "Already executed");
        require(proposal.forVotes > proposal.againstVotes, "Proposal rejected");
        
        proposal.executed = true;
        
        emit ProposalExecuted(proposalId);
        
        // NOTE: Actual execution logic would go here
        // This is a basic framework - extend based on proposal types
    }
    
    /// @notice Get proposal details
    /// @param proposalId ID of the proposal
    function getProposal(uint256 proposalId) 
        external 
        view 
        returns (
            address proposer,
            string memory description,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 endTime,
            bool executed,
            bool passed
        ) 
    {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        
        Proposal storage proposal = proposals[proposalId];
        
        return (
            proposal.proposer,
            proposal.description,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.endTime,
            proposal.executed,
            proposal.forVotes > proposal.againstVotes
        );
    }
    
    /// @notice Check if address has voted on a proposal
    /// @param proposalId ID of the proposal
    /// @param voter Address to check
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        return proposals[proposalId].hasVoted[voter];
    }
}

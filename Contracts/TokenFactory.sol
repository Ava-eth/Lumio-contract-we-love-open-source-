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
    address[] public deployedTokens;

    event TokenDeployed(address indexed token, address indexed creator, string name, string symbol, uint256 supply);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event FeeRefunded(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

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
     * @dev Uses call instead of transfer (H1 fix)
     */
    function withdrawTreasury(address to) external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No funds");
        require(to != address(0), "Invalid recipient");

        (bool success, ) = payable(to).call{value: bal}("");
        require(success, "ETH transfer failed");

        emit TreasuryWithdrawn(to, bal);
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
    bool public mintable;
    bool public burnable;
    bool public pausable;

    event Minted(address indexed to, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);

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
}

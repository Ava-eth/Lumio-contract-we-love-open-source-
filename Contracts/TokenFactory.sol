// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Lumio ERC20 Factory
/// @notice Deploys ERC20 tokens with user-selected features
contract LumioERC20Factory is Ownable {
    uint256 public constant DEPLOYMENT_FEE = 5000 ether; // Fee to deploy token
    address[] public deployedTokens;

    event TokenDeployed(address indexed token, address indexed creator, string name, string symbol, uint256 supply);
    event TreasuryWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {
        // Treasury is always the factory itself
    }

    /// @notice Deploy a new customizable ERC20 token
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

        // Deploy token with requested params
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

        // Refund any extra ETH
        if (msg.value > DEPLOYMENT_FEE) {
            payable(msg.sender).transfer(msg.value - DEPLOYMENT_FEE);
        }
    }

    /// @notice Withdraw collected deployment fees
    function withdrawTreasury(address to) external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No funds");
        require(to != address(0), "Invalid recipient");

        payable(to).transfer(bal);
        emit TreasuryWithdrawn(to, bal);
    }

    function getDeployedTokens() external view returns (address[] memory) {
        return deployedTokens;
    }
}

/// @title Customizable ERC20 Token
contract CustomERC20 is ERC20, ERC20Burnable, ERC20Pausable, ERC20Capped, Ownable {
    uint8 private immutable customDecimals;
    bool public mintable;
    bool public burnable;
    bool public pausable;

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

        _mint(_owner, _initialSupply);
    }

    /// @notice Override decimals
    function decimals() public view override returns (uint8) {
        return customDecimals;
    }

    /// @notice Mint new tokens if mintable
    function mint(address to, uint256 amount) external onlyOwner {
        require(mintable, "Minting disabled");
        _mint(to, amount);
    }

    /// @notice Pause transfers if pausable
    function pause() external onlyOwner {
        require(pausable, "Pause disabled");
        _pause();
    }

    function unpause() external onlyOwner {
        require(pausable, "Pause disabled");
        _unpause();
    }

    // === Overrides ===
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Pausable, ERC20Capped)
    {
        super._update(from, to, amount);
    }
}

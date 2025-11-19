// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LumioToken is ERC20, Ownable {
    uint256 private constant TOTAL_SUPPLY = 10_000_000 * 10**18; // 10M tokens (18 decimals)

    constructor()
        ERC20("Lumio", "LYT")
        Ownable(msg.sender)  // <-- Pass msg.sender to Ownable
    {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // Optional: Uncomment if you want to allow the owner to mint more tokens later.
    /*
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
    */
}
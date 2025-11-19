// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * @title VerifierOracle
 * @notice Verifies domain ownership using Space ID API (off-chain or manually updated).
 * @dev This contract maintains a mapping of verified wallet addresses to their domain names.
 */

import "@openzeppelin/contracts/access/Ownable.sol";

contract VerifierOracle is Ownable {
    mapping(address => string) public verifiedDomains;

    event DomainVerified(address indexed user, string domain);
    event DomainRevoked(address indexed user, string domain);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Update verification manually (API call should trigger this via backend or keeper)
     * @param user The wallet address to verify
     * @param domain The domain name to associate with the address
     */
    function updateVerification(address user, string calldata domain) external onlyOwner {
        require(user != address(0), "Invalid address");
        require(bytes(domain).length > 0, "Empty domain");
        
        verifiedDomains[user] = domain;
        emit DomainVerified(user, domain);
    }

    /**
     * @notice Revoke domain verification for a user
     * @param user The wallet address to revoke verification for
     */
    function revokeVerification(address user) external onlyOwner {
        require(user != address(0), "Invalid address");
        string memory oldDomain = verifiedDomains[user];
        require(bytes(oldDomain).length > 0, "No domain to revoke");
        
        delete verifiedDomains[user];
        emit DomainRevoked(user, oldDomain);
    }

    /**
     * @notice Batch update multiple verifications
     * @param users Array of wallet addresses
     * @param domains Array of domain names (must match length of users)
     */
    function batchUpdateVerification(address[] calldata users, string[] calldata domains) external onlyOwner {
        require(users.length == domains.length, "Length mismatch");
        require(users.length > 0, "Empty array");
        require(users.length <= 100, "Batch too large");
        
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid address");
            require(bytes(domains[i]).length > 0, "Empty domain");
            
            verifiedDomains[users[i]] = domains[i];
            emit DomainVerified(users[i], domains[i]);
        }
    }

    /**
     * @notice Contract reads here to confirm wallet-domain match
     * @param user The wallet address to verify
     * @param domain The domain name to check
     * @return bool True if the domain matches the verified domain for the user
     */
    function verifyDomain(address user, string calldata domain) external view returns (bool) {
        return keccak256(abi.encodePacked(verifiedDomains[user])) == keccak256(abi.encodePacked(domain));
    }

    /**
     * @notice Get the verified domain for a user
     * @param user The wallet address to query
     * @return string The verified domain name (empty string if not verified)
     */
    function getVerifiedDomain(address user) external view returns (string memory) {
        return verifiedDomains[user];
    }

    /**
     * @notice Check if a user has any verified domain
     * @param user The wallet address to check
     * @return bool True if the user has a verified domain
     */
    function isVerified(address user) external view returns (bool) {
        return bytes(verifiedDomains[user]).length > 0;
    }
}

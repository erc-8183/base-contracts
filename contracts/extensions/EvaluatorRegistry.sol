// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title EvaluatorRegistry
 * @notice Optional evaluator discovery for ERC-8183 AgenticCommerce.
 *         Allows agents to look up domain-specific evaluators instead of
 *         hardcoding evaluator addresses.
 *
 * @dev Not required by the core protocol — this is a convenience extension.
 *      Agents and frontends can query `getEvaluator(domain)` to discover
 *      which evaluator to use for a given job type.
 *
 *      Domains are free-form strings (e.g., "trust", "code-review",
 *      "content-moderation"). Each domain maps to exactly one evaluator
 *      address.
 *
 * Example flow:
 *   1. Evaluator provider registers: registry.register("trust", 0xMaiat...)
 *   2. Client creating a job queries: registry.getEvaluator("trust")
 *   3. Client passes returned address as `evaluator` param in createJob()
 */
contract EvaluatorRegistry is OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice domain → evaluator address
    mapping(string => address) private _evaluators;

    /// @notice evaluator address → metadata URI (optional)
    mapping(address => string) private _metadataURIs;

    /// @notice All registered domain names (for enumeration)
    string[] private _domains;

    /// @notice domain → index in _domains array (1-indexed, 0 = not found)
    mapping(string => uint256) private _domainIndex;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event EvaluatorRegistered(string indexed domain, address indexed evaluator);
    event EvaluatorRemoved(string indexed domain, address indexed evaluator);
    event MetadataUpdated(address indexed evaluator, string uri);

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error EvaluatorRegistry__ZeroAddress();
    error EvaluatorRegistry__EmptyDomain();
    error EvaluatorRegistry__DomainNotFound(string domain);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC: REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register an evaluator for a domain. Overwrites if exists.
     * @param domain Free-form domain string (e.g., "trust", "code-review")
     * @param evaluator Address of the evaluator contract
     */
    function register(string calldata domain, address evaluator) external onlyOwner {
        if (evaluator == address(0)) revert EvaluatorRegistry__ZeroAddress();
        if (bytes(domain).length == 0) revert EvaluatorRegistry__EmptyDomain();

        // Track domain for enumeration
        if (_domainIndex[domain] == 0) {
            _domains.push(domain);
            _domainIndex[domain] = _domains.length; // 1-indexed
        }

        _evaluators[domain] = evaluator;
        emit EvaluatorRegistered(domain, evaluator);
    }

    /**
     * @notice Remove an evaluator from a domain.
     * @param domain Domain to remove
     */
    function remove(string calldata domain) external onlyOwner {
        address current = _evaluators[domain];
        if (current == address(0)) revert EvaluatorRegistry__DomainNotFound(domain);

        delete _evaluators[domain];

        // Remove from _domains array (swap with last)
        uint256 idx = _domainIndex[domain];
        if (idx > 0) {
            uint256 lastIdx = _domains.length;
            if (idx != lastIdx) {
                string memory lastDomain = _domains[lastIdx - 1];
                _domains[idx - 1] = lastDomain;
                _domainIndex[lastDomain] = idx;
            }
            _domains.pop();
            delete _domainIndex[domain];
        }

        emit EvaluatorRemoved(domain, current);
    }

    /**
     * @notice Set metadata URI for an evaluator (e.g., IPFS docs, API endpoint).
     * @param evaluator Address of the evaluator
     * @param uri Metadata URI
     */
    function setMetadata(address evaluator, string calldata uri) external onlyOwner {
        if (evaluator == address(0)) revert EvaluatorRegistry__ZeroAddress();
        _metadataURIs[evaluator] = uri;
        emit MetadataUpdated(evaluator, uri);
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC: QUERIES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Look up the evaluator for a domain.
     * @param domain Domain to query
     * @return evaluator Address of the evaluator (address(0) if not found)
     */
    function getEvaluator(string calldata domain) external view returns (address) {
        return _evaluators[domain];
    }

    /**
     * @notice Get metadata URI for an evaluator.
     * @param evaluator Address to query
     * @return uri Metadata URI (empty string if not set)
     */
    function getMetadata(address evaluator) external view returns (string memory) {
        return _metadataURIs[evaluator];
    }

    /**
     * @notice Get all registered domains.
     * @return List of domain strings
     */
    function getDomains() external view returns (string[] memory) {
        return _domains;
    }

    /**
     * @notice Get total number of registered domains.
     */
    function domainCount() external view returns (uint256) {
        return _domains.length;
    }
}

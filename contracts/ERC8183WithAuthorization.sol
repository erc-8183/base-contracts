// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./ERC8183.sol";

/// @title ERC8183WithAuthorization
/// @notice Adds EIP-712 signed authorization entrypoints to ERC8183.
contract ERC8183WithAuthorization is ERC8183, EIP712Upgradeable {
    bytes32 public constant CREATE_JOB_AUTHORIZATION_TYPEHASH = keccak256(
        "CreateJobAuthorization(address signer,address provider,address evaluator,uint48 expiredAt,bytes32 descriptionHash,address hook,uint256 providerAgentId,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_PROVIDER_AUTHORIZATION_TYPEHASH = keccak256(
        "SetProviderAuthorization(address signer,uint256 jobId,address provider,uint256 agentId,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_BUDGET_AUTHORIZATION_TYPEHASH = keccak256(
        "SetBudgetAuthorization(address signer,uint256 jobId,address token,uint256 amount,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant FUND_AUTHORIZATION_TYPEHASH = keccak256(
        "FundAuthorization(address signer,uint256 jobId,uint256 expectedBudget,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant SUBMIT_AUTHORIZATION_TYPEHASH = keccak256(
        "SubmitAuthorization(address signer,uint256 jobId,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant COMPLETE_AUTHORIZATION_TYPEHASH = keccak256(
        "CompleteAuthorization(address signer,uint256 jobId,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant REJECT_AUTHORIZATION_TYPEHASH = keccak256(
        "RejectAuthorization(address signer,uint256 jobId,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );

    /// @notice Tracks used packed nonces: bytes20(signer) || uint72 nonce.
    mapping(bytes32 => bool) public authorizationNonceUsed;

    struct Authorization {
        address signer;
        uint72 nonce;
        uint256 deadline;
        bytes sig;
    }

    struct CreateJobAuthorizationParams {
        address provider;
        address evaluator;
        uint48 expiredAt;
        string description;
        address hook;
        uint256 providerAgentId;
    }

    event AuthorizationUsed(address indexed signer, bytes32 indexed nonce);

    error AuthorizationExpired();
    error AuthorizationNonceUsed();
    error InvalidAuthorizationSignature();

    function initialize(address treasury_, address admin_) public override initializer {
        __ERC8183_init(treasury_, admin_);
        __EIP712_init("ERC8183WithAuthorization", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function createJobWithAuthorization(
        CreateJobAuthorizationParams calldata params,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant returns (uint256) {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    CREATE_JOB_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    params.provider,
                    params.evaluator,
                    params.expiredAt,
                    keccak256(bytes(params.description)),
                    params.hook,
                    params.providerAgentId,
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        return _createJob(
            auth.signer,
            params.provider,
            params.evaluator,
            params.expiredAt,
            params.description,
            params.hook,
            params.providerAgentId
        );
    }

    function setProviderWithAuthorization(
        uint256 jobId,
        address provider_,
        uint256 agentId,
        Authorization calldata auth
    ) external whenNotPaused {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(SET_PROVIDER_AUTHORIZATION_TYPEHASH, auth.signer, jobId, provider_, agentId, auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _setProvider(auth.signer, jobId, provider_, agentId);
    }

    function setBudgetWithAuthorization(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    SET_BUDGET_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    jobId,
                    token,
                    amount,
                    keccak256(optParams),
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        _setBudget(auth.signer, jobId, token, amount, optParams);
    }

    function fundWithAuthorization(
        uint256 jobId,
        uint256 expectedBudget,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(FUND_AUTHORIZATION_TYPEHASH, auth.signer, jobId, expectedBudget, keccak256(optParams), auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _fund(auth.signer, jobId, expectedBudget, optParams);
    }

    function submitWithAuthorization(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(SUBMIT_AUTHORIZATION_TYPEHASH, auth.signer, jobId, deliverable, keccak256(optParams), auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _submit(auth.signer, jobId, deliverable, optParams);
    }

    function completeWithAuthorization(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(COMPLETE_AUTHORIZATION_TYPEHASH, auth.signer, jobId, reason, keccak256(optParams), auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _complete(auth.signer, jobId, reason, optParams);
    }

    function rejectWithAuthorization(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(REJECT_AUTHORIZATION_TYPEHASH, auth.signer, jobId, reason, keccak256(optParams), auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _reject(auth.signer, jobId, reason, optParams);
    }

    function _verifyAuthorization(
        address signer,
        uint72 nonce,
        uint256 deadline,
        bytes32 structHash,
        bytes calldata sig
    ) internal {
        if (block.timestamp > deadline) revert AuthorizationExpired();
        bytes32 packedNonce = _packAuthorizationNonce(signer, nonce);
        if (authorizationNonceUsed[packedNonce]) revert AuthorizationNonceUsed();
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNowCalldata(signer, digest, sig)) revert InvalidAuthorizationSignature();
        authorizationNonceUsed[packedNonce] = true;
        emit AuthorizationUsed(signer, packedNonce);
    }

    function _packAuthorizationNonce(address signer, uint72 nonce) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(signer)) << 96) | uint256(nonce));
    }
}

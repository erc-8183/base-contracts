// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./ERC8183.sol";

/// @title ERC8183WithIntent
/// @notice Adds EIP-712 signed intent entrypoints to ERC8183.
contract ERC8183WithIntent is ERC8183, EIP712Upgradeable {
    bytes32 public constant CREATE_JOB_INTENT_TYPEHASH = keccak256(
        "CreateJobIntent(address signer,address provider,address evaluator,uint48 expiredAt,bytes32 descriptionHash,address hook,uint256 providerAgentId,bytes32 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_PROVIDER_INTENT_TYPEHASH = keccak256(
        "SetProviderIntent(address signer,uint256 jobId,address provider,uint256 agentId,bytes32 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_BUDGET_INTENT_TYPEHASH = keccak256(
        "SetBudgetIntent(address signer,uint256 jobId,address token,uint256 amount,bytes32 optParamsHash,bytes32 nonce,uint256 deadline)"
    );
    bytes32 public constant FUND_INTENT_TYPEHASH = keccak256(
        "FundIntent(address signer,uint256 jobId,uint256 expectedBudget,bytes32 optParamsHash,bytes32 nonce,uint256 deadline)"
    );
    bytes32 public constant SUBMIT_INTENT_TYPEHASH = keccak256(
        "SubmitIntent(address signer,uint256 jobId,bytes32 deliverable,bytes32 optParamsHash,bytes32 nonce,uint256 deadline)"
    );
    bytes32 public constant REJECT_INTENT_TYPEHASH = keccak256(
        "RejectIntent(address signer,uint256 jobId,bytes32 reason,bytes32 optParamsHash,bytes32 nonce,uint256 deadline)"
    );

    mapping(address => mapping(bytes32 => bool)) public intentNonceUsed;

    struct IntentAuthorization {
        address signer;
        bytes32 nonce;
        uint256 deadline;
        bytes sig;
    }

    struct CreateJobIntentParams {
        address provider;
        address evaluator;
        uint48 expiredAt;
        string description;
        address hook;
        uint256 providerAgentId;
    }

    event IntentExecuted(address indexed signer, bytes32 indexed nonce);

    error IntentExpired();
    error IntentNonceUsed();
    error InvalidIntentSignature();

    function initialize(address treasury_, address admin_) public override initializer {
        __ERC8183_init(treasury_, admin_);
        __EIP712_init("ERC8183WithIntent", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function createJobWithIntent(
        CreateJobIntentParams calldata params,
        IntentAuthorization calldata auth
    ) external whenNotPaused nonReentrant returns (uint256) {
        _verifyIntent(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    CREATE_JOB_INTENT_TYPEHASH,
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

    function setProviderWithIntent(
        uint256 jobId,
        address provider_,
        uint256 agentId,
        IntentAuthorization calldata auth
    ) external whenNotPaused {
        _verifyIntent(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(SET_PROVIDER_INTENT_TYPEHASH, auth.signer, jobId, provider_, agentId, auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _setProvider(auth.signer, jobId, provider_, agentId);
    }

    function setBudgetWithIntent(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams,
        IntentAuthorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyIntent(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    SET_BUDGET_INTENT_TYPEHASH,
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

    function fundWithIntent(
        uint256 jobId,
        uint256 expectedBudget,
        bytes calldata optParams,
        IntentAuthorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyIntent(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(FUND_INTENT_TYPEHASH, auth.signer, jobId, expectedBudget, keccak256(optParams), auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _fund(auth.signer, jobId, expectedBudget, optParams);
    }

    function submitWithIntent(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams,
        IntentAuthorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyIntent(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(SUBMIT_INTENT_TYPEHASH, auth.signer, jobId, deliverable, keccak256(optParams), auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _submit(auth.signer, jobId, deliverable, optParams);
    }

    function rejectWithIntent(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams,
        IntentAuthorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyIntent(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(REJECT_INTENT_TYPEHASH, auth.signer, jobId, reason, keccak256(optParams), auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _reject(auth.signer, jobId, reason, optParams);
    }

    function _verifyIntent(
        address signer,
        bytes32 nonce,
        uint256 deadline,
        bytes32 structHash,
        bytes calldata sig
    ) internal {
        if (block.timestamp > deadline) revert IntentExpired();
        if (intentNonceUsed[signer][nonce]) revert IntentNonceUsed();
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNowCalldata(signer, digest, sig)) revert InvalidIntentSignature();
        intentNonceUsed[signer][nonce] = true;
        emit IntentExecuted(signer, nonce);
    }
}

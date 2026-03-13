// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC8001} from "./interfaces/IERC8001.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title ERC8001
 * @dev Base implementation of ERC-8001 Agent Coordination Framework.
 *
 * This contract provides the core coordination primitives:
 * - Propose: Initiator posts a signed intent with required participants
 * - Accept: Each participant signs an acceptance attestation
 * - Execute: Once all participants accept, anyone can trigger execution
 *
 * EIP-712 Domain: {name: "ERC-8001", version: "1", chainId, verifyingContract}
 *
 * Execution logic is left to inheriting contracts via the `_executeCoordination` hook.
 *
 * See https://eips.ethereum.org/EIPS/eip-8001
 */
abstract contract ERC8001 is IERC8001, EIP712 {
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev EIP-712 typehash for AgentIntent (as defined in the spec)
    bytes32 public constant AGENT_INTENT_TYPEHASH = keccak256(
        "AgentIntent(bytes32 payloadHash,uint64 expiry,uint64 nonce,address agentId,bytes32 coordinationType,uint256 coordinationValue,address[] participants)"
    );

    /// @dev EIP-712 typehash for AcceptanceAttestation (as defined in the spec)
    bytes32 public constant ACCEPTANCE_TYPEHASH = keccak256(
        "AcceptanceAttestation(bytes32 intentHash,address participant,uint64 nonce,uint64 expiry,bytes32 conditionsHash)"
    );

    /// @dev EIP-1271 magic value for valid signatures
    bytes4 private constant EIP1271_MAGIC = 0x1626ba7e;

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Per-participant acceptance record
    struct AcceptanceRecord {
        bool accepted;
        uint64 expiry;       // When this acceptance expires
        uint64 nonce;        // Acceptance-level nonce (optional per spec)
    }

    /// @dev Coordination state by intent hash
    struct CoordinationState {
        Status status;
        bytes32 payloadHash;
        address proposer;
        uint64 expiry;
        address[] participants;
        mapping(address => AcceptanceRecord) acceptances;
        uint256 acceptedCount;
    }

    /// @dev Intent hash => coordination state
    mapping(bytes32 => CoordinationState) internal _coordinations;

    /// @dev Agent address => current nonce (for intent replay protection)
    mapping(address => uint64) internal _agentNonces;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Initializes the EIP-712 domain with hardcoded ERC-8001 values.
     */
    constructor() EIP712("ERC-8001", "1") {}

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IERC8001
    function proposeCoordination(
        AgentIntent calldata intent,
        bytes calldata signature,
        CoordinationPayload calldata payload
    ) public virtual returns (bytes32 intentHash) {
        // Validate expiry
        if (intent.expiry <= block.timestamp) {
            revert ERC8001_ExpiredIntent();
        }

        // Validate nonce
        uint64 currentNonce = _agentNonces[intent.agentId];
        if (intent.nonce <= currentNonce) {
            revert ERC8001_NonceTooLow();
        }

        // Validate participants are strictly ascending and unique
        _validateParticipantsCanonical(intent.participants);

        // Validate agentId is in participants list
        bool agentIsParticipant = false;
        for (uint256 i = 0; i < intent.participants.length; i++) {
            if (intent.participants[i] == intent.agentId) {
                agentIsParticipant = true;
                break;
            }
        }
        if (!agentIsParticipant) {
            revert ERC8001_NotParticipant();
        }

        // Compute intent struct hash (as defined in the spec)
        intentHash = _hashIntent(intent);

        // Check intent doesn't already exist
        if (_coordinations[intentHash].status != Status.None) {
            revert ERC8001_DuplicateAcceptance();
        }

        // Verify payload hash matches
        bytes32 computedPayloadHash = _hashPayload(payload);
        if (intent.payloadHash != computedPayloadHash) {
            revert ERC8001_PayloadHashMismatch();
        }

        // Verify signature
        bytes32 digest = _hashTypedDataV4(intentHash);
        if (!_verifySignature(intent.agentId, digest, signature)) {
            revert ERC8001_BadSignature();
        }

        // Update nonce
        _agentNonces[intent.agentId] = intent.nonce;

        // Store coordination
        CoordinationState storage coord = _coordinations[intentHash];
        coord.status = Status.Proposed;
        coord.payloadHash = intent.payloadHash;
        coord.proposer = intent.agentId;
        coord.expiry = intent.expiry;
        coord.participants = intent.participants;

        // Proposer auto-accepts if they're a participant
        for (uint256 i = 0; i < intent.participants.length; i++) {
            if (intent.participants[i] == intent.agentId) {
                coord.acceptances[intent.agentId].accepted = true;
                coord.acceptances[intent.agentId].expiry = intent.expiry; // Use intent expiry as acceptance expiry
                coord.acceptedCount = 1;
                break;
            }
        }

        emit CoordinationProposed(
            intentHash,
            intent.agentId,
            intent.coordinationType,
            intent.participants.length,
            intent.coordinationValue
        );

        // Check if ready (single participant case)
        if (coord.acceptedCount == coord.participants.length) {
            coord.status = Status.Ready;
        }

        return intentHash;
    }

    /// @inheritdoc IERC8001
    function acceptCoordination(bytes32 intentHash, AcceptanceAttestation calldata attestation)
    public
    virtual
    returns (bool allAccepted)
    {
        CoordinationState storage coord = _coordinations[intentHash];

        // Validate coordination exists and is proposed
        if (coord.status == Status.None) {
            revert ERC8001_NotReady();
        }
        if (coord.status != Status.Proposed && coord.status != Status.Ready) {
            revert ERC8001_NotReady();
        }

        // Validate intent not expired
        if (coord.expiry <= block.timestamp) {
            revert ERC8001_ExpiredIntent();
        }

        // Validate acceptance attestation matches intent
        if (attestation.intentHash != intentHash) {
            revert ERC8001_PayloadHashMismatch();
        }

        // Validate acceptance expiry
        if (attestation.expiry <= block.timestamp) {
            revert ERC8001_ExpiredAcceptance(attestation.participant);
        }

        // The caller must be the participant
        if (msg.sender != attestation.participant) {
            revert ERC8001_NotParticipant();
        }

        // Check participant is required
        bool isParticipant = false;
        for (uint256 i = 0; i < coord.participants.length; i++) {
            if (coord.participants[i] == attestation.participant) {
                isParticipant = true;
                break;
            }
        }
        if (!isParticipant) {
            revert ERC8001_NotParticipant();
        }

        // Check not already accepted
        if (coord.acceptances[attestation.participant].accepted) {
            revert ERC8001_DuplicateAcceptance();
        }

        // Verify signature (from the attestation)
        bytes32 attestationStructHash = _hashAttestation(attestation);
        bytes32 digest = _hashTypedDataV4(attestationStructHash);
        if (!_verifySignature(attestation.participant, digest, attestation.signature)) {
            revert ERC8001_BadSignature();
        }

        // Record acceptance
        coord.acceptances[attestation.participant].accepted = true;
        coord.acceptances[attestation.participant].expiry = attestation.expiry;
        coord.acceptances[attestation.participant].nonce = attestation.nonce;
        coord.acceptedCount++;

        bytes32 acceptanceHash = keccak256(abi.encode(attestation));

        emit CoordinationAccepted(
            intentHash,
            attestation.participant,
            acceptanceHash,
            coord.acceptedCount,
            coord.participants.length
        );

        // Check if all participants have accepted
        if (coord.acceptedCount == coord.participants.length) {
            coord.status = Status.Ready;
            return true;
        }

        return false;
    }

    /// @inheritdoc IERC8001
    function executeCoordination(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData
    ) public virtual returns (bool success, bytes memory result) {
        CoordinationState storage coord = _coordinations[intentHash];

        // Validate status is Ready
        if (coord.status != Status.Ready) {
            revert ERC8001_NotReady();
        }

        // Validate intent not expired
        if (coord.expiry <= block.timestamp) {
            revert ERC8001_ExpiredIntent();
        }

        // Validate all acceptances have not expired
        for (uint256 i = 0; i < coord.participants.length; i++) {
            address participant = coord.participants[i];
            if (coord.acceptances[participant].expiry <= block.timestamp) {
                revert ERC8001_ExpiredAcceptance(participant);
            }
        }

        // Verify payload matches
        bytes32 computedPayloadHash = _hashPayload(payload);
        if (coord.payloadHash != computedPayloadHash) {
            revert ERC8001_PayloadHashMismatch();
        }

        // Update status before execution (reentrancy protection)
        coord.status = Status.Executed;

        // Execute application-specific logic
        uint256 gasBefore = gasleft();
        (success, result) = _executeCoordinationHook(intentHash, payload, executionData);
        uint256 gasUsed = gasBefore - gasleft();

        emit CoordinationExecuted(intentHash, msg.sender, success, gasUsed, result);
    }

    /// @inheritdoc IERC8001
    function cancelCoordination(bytes32 intentHash, string calldata reason) public virtual {
        CoordinationState storage coord = _coordinations[intentHash];

        if (coord.status == Status.None) {
            revert ERC8001_NotReady();
        }
        if (coord.status == Status.Executed || coord.status == Status.Cancelled) {
            revert ERC8001_NotReady();
        }

        // Before expiry: only proposer can cancel
        // After expiry: anyone can cancel
        if (coord.expiry > block.timestamp && msg.sender != coord.proposer) {
            revert ERC8001_NotProposer();
        }

        coord.status = Status.Cancelled;

        emit CoordinationCancelled(intentHash, msg.sender, reason, uint8(Status.Cancelled));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IERC8001
    function getCoordinationStatus(bytes32 intentHash)
    public
    view
    virtual
    returns (
        Status status,
        address proposer,
        address[] memory participants,
        address[] memory acceptedBy,
        uint256 expiry
    )
    {
        CoordinationState storage coord = _coordinations[intentHash];

        // Compute dynamic status
        status = coord.status;
        if (status == Status.Proposed || status == Status.Ready) {
            if (block.timestamp >= coord.expiry) {
                status = Status.Expired;
            }
        }

        proposer = coord.proposer;
        participants = coord.participants;
        expiry = coord.expiry;

        // Build acceptedBy array
        uint256 acceptedCount = 0;
        for (uint256 i = 0; i < coord.participants.length; i++) {
            if (coord.acceptances[coord.participants[i]].accepted) {
                acceptedCount++;
            }
        }
        acceptedBy = new address[](acceptedCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < coord.participants.length && idx < acceptedCount; i++) {
            if (coord.acceptances[coord.participants[i]].accepted) {
                acceptedBy[idx++] = coord.participants[i];
            }
        }
    }

    /// @inheritdoc IERC8001
    function getRequiredAcceptances(bytes32 intentHash) public view virtual returns (uint256 count) {
        return _coordinations[intentHash].participants.length;
    }

    /// @inheritdoc IERC8001
    function getAgentNonce(address agent) public view virtual returns (uint64) {
        return _agentNonces[agent];
    }

    /**
     * @notice Check if a participant has accepted a coordination.
     * @param intentHash  The coordination to check
     * @param participant The participant to check
     * @return hasAccepted True if the participant has accepted
     */
    function hasAccepted(bytes32 intentHash, address participant)
    public
    view
    virtual
    returns (bool)
    {
        return _coordinations[intentHash].acceptances[participant].accepted;
    }

    /// @inheritdoc IERC8001
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc IERC8001
    function getIntentHash(AgentIntent calldata intent) public pure virtual returns (bytes32) {
        return _hashIntent(intent);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Hook for application-specific execution logic.
     *      MUST be implemented by inheriting contracts.
     * @param intentHash    The coordination being executed
     * @param payload       The coordination payload
     * @param executionData Optional execution-specific data
     * @return success Whether execution succeeded
     * @return result  Return data from execution
     */
    function _executeCoordinationHook(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData
    ) internal virtual returns (bool success, bytes memory result);

    /**
     * @dev Compute the EIP-712 struct hash for an AgentIntent.
     *      Per spec: keccak256(abi.encode(AGENT_INTENT_TYPEHASH, ...))
     */
    function _hashIntent(AgentIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                AGENT_INTENT_TYPEHASH,
                intent.payloadHash,
                intent.expiry,
                intent.nonce,
                intent.agentId,
                intent.coordinationType,
                intent.coordinationValue,
                keccak256(abi.encodePacked(intent.participants))
            )
        );
    }

    /**
     * @dev Compute the EIP-712 struct hash for an AcceptanceAttestation.
     *      Per spec: keccak256(abi.encode(ACCEPTANCE_TYPEHASH, ...))
     *      Note: signature is NOT part of the hash (it's inside the struct but not signed over)
     */
    function _hashAttestation(AcceptanceAttestation calldata attestation)
    internal
    pure
    returns (bytes32)
    {
        return keccak256(
            abi.encode(
                ACCEPTANCE_TYPEHASH,
                attestation.intentHash,
                attestation.participant,
                attestation.nonce,
                attestation.expiry,
                attestation.conditionsHash
            )
        );
    }

    /**
     * @dev Compute the hash of a CoordinationPayload.
     *      Per spec: hash of all fields including metadata
     */
    function _hashPayload(CoordinationPayload calldata payload) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                payload.version,
                payload.coordinationType,
                keccak256(payload.coordinationData),
                payload.conditionsHash,
                payload.timestamp,
                keccak256(payload.metadata)
            )
        );
    }

    /**
     * @dev Validate that participants array is strictly ascending and unique.
     *      Per spec: participants MUST be unique and strictly ascending by uint160(address).
     */
    function _validateParticipantsCanonical(address[] calldata participants) internal pure {
        if (participants.length == 0) {
            revert ERC8001_ParticipantsNotCanonical();
        }
        for (uint256 i = 1; i < participants.length; i++) {
            if (uint160(participants[i]) <= uint160(participants[i - 1])) {
                revert ERC8001_ParticipantsNotCanonical();
            }
        }
    }

    /**
     * @dev Verify a signature from an agent (EOA or ERC-1271 contract).
     * @param signer    Expected signer address
     * @param digest    EIP-712 digest to verify
     * @param signature Signature bytes (65 or 64 bytes for ECDSA, arbitrary for ERC-1271)
     * @return valid    True if signature is valid
     */
    function _verifySignature(address signer, bytes32 digest, bytes calldata signature)
    internal
    view
    returns (bool)
    {
        // Contract signer - use ERC-1271
        if (signer.code.length > 0) {
            try IERC1271(signer).isValidSignature(digest, signature) returns (bytes4 magic) {
                return magic == EIP1271_MAGIC;
            } catch {
                return false;
            }
        }

        // EOA signature - use ECDSA recovery
        address recovered = digest.recover(signature);
        return recovered == signer;
    }

    /**
     * @dev Get coordination state for internal use.
     */
    function _getCoordination(bytes32 intentHash)
    internal
    view
    returns (CoordinationState storage)
    {
        return _coordinations[intentHash];
    }
}
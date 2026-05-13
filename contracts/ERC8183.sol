// SPDX-License-Identifier: MIT
// ERC-8183: Agentic Commerce Protocol — Reference Implementation
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "./IERC8183Hook.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

/**
 * @title ERC8183
 * @dev Reference implementation of ERC-8183: Agentic Commerce Protocol.
 *      Implements a job escrow state machine with optional hook extension points.
 *      Core state machine: Open -> Funded -> Submitted -> Completed | Rejected | Expired.
 *
 *      Hooks (IERC8183Hook):
 *        before* — called BEFORE state change, CAN revert to gate the transition.
 *        after*  — called AFTER state change for bookkeeping/side effects.
 *
 *      When hook == address(0), the contract operates as a standalone job escrow.
 */
contract ERC8183 is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable, EIP712Upgradeable {
    using SafeERC20 for IERC20;

    /// @notice Job lifecycle states
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    /// @notice Core job data, packed into 8 storage slots
    /// @param client           Job creator who funds the escrow
    /// @param status           Current lifecycle state
    /// @param provider         Service provider who delivers work
    /// @param expiredAt        Unix timestamp after which the job can be expired
    /// @param evaluator        Third-party attestor
    /// @param submittedAt      Unix timestamp when provider submitted work
    /// @param budget           Escrowed payment amount in paymentToken units
    /// @param settledAmount    Cumulative gross amount released via partial settlement vouchers
    /// @param hook             Hook contract for before/after callbacks (address(0) = no hook)
    /// @param paymentToken     ERC-20 token used for job payment
    /// @param providerAgentId  Optional ERC-8004 agent identity for provider
    /// @param description      Human-readable job description
    struct Job {
        address client;             // 20 ──┐ slot 1
        JobStatus status;           // 1  ──┘
        address provider;           // 20 ──┐ slot 2
        uint48 expiredAt;           // 6  ──┘
        address evaluator;          // 20 ──┐ slot 3
        uint48 submittedAt;         // 6  ──┘
        uint256 budget;             // 32 ──  slot 4
        uint256 settledAmount;      // 32 ──  slot 5
        address hook;               // 20 ──  slot 6
        address paymentToken;       // 20 ──  slot 7
        uint256 providerAgentId;    // 32 ──  slot 8
        string description;         //        slot 9+
    }

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    string public constant EIP712_NAME = "ERC8183";
    string public constant EIP712_VERSION = "1";

    /// @notice EIP-712 type hash for the partial-settlement Voucher struct.
    /// @dev    chainId and verifyingContract are bound by the EIP-712 domain separator.
    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256(
            "Voucher(uint256 jobId,uint256 cumulativeAmount,bytes optParams)"
        );

    /// @notice EIP-712 type hash for the claim-voucher struct used by submitClaim.
    /// @dev    Binds the deliverable into the signed payload so the client's
    ///         signature attests to BOTH the amount released and the work
    ///         delivered. `deliverable` is hashed with keccak256 in the struct
    ///         hash per EIP-712 dynamic-bytes encoding rules.
    bytes32 public constant CLAIM_VOUCHER_TYPEHASH =
        keccak256(
            "ClaimVoucher(uint256 jobId,uint256 cumulativeAmount,bytes deliverable,bytes optParams)"
        );

    /// @notice Grace period after expiry during which only the evaluator can finalize a Submitted job.
    ///         Prevents third-party censorship of providers who submitted work before expiry.
    uint256 public constant EVALUATION_GRACE_PERIOD = 1 hours;

    /// @notice Platform fee in basis points (10000 = 100%)
    uint256 public platformFeeBP; // 10000 = 100%
    /// @notice Address that receives platform fees
    address public platformTreasury;
    /// @notice Evaluator fee in basis points (10000 = 100%)
    uint256 public evaluatorFeeBP;

    /// @notice Job ID -> Job data
    mapping(uint256 => Job) public jobs;
    /// @notice Motonically increasing job ID counter
    uint256 public jobCounter;
    /// @notice Hook address -> whether it is whitelisted for use
    mapping(address => bool) public whitelistedHooks;
    /// @notice ERC-20 token -> whether it is allowed as a payment token
    /// @dev    Allowlist enforces that only tokens with vetted ERC-20 semantics
    ///         (no fee-on-transfer, no rebase, no transfer hooks, no pause/blacklist
    ///         that would lock escrowed funds) can be used for job budgets.
    mapping(address => bool) public allowedPaymentTokens;
    /// @notice Job ID -> hash binding the pending slow-path claim.
    /// @dev    Hash = keccak256(abi.encode(cumulativeAmount, keccak256(deliverable))).
    ///         Value of bytes32(0) means no pending claim. Caller of approveClaim /
    ///         rejectClaim must supply the preimage components for verification.
    ///         Single-slot storage; only one pending claim per job at a time.
    mapping(uint256 => bytes32) public pendingClaimHash;

    /// @notice Emitted when a new job is created
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        uint48 expiredAt,
        address hook
    );
    /// @notice Emitted when a provider is assigned to a job
    event ProviderSet(
        uint256 indexed jobId, 
        address indexed provider, 
        uint256 agentId
    );
    /// @notice Emitted when the provider sets or updates the job budget
    event BudgetSet(
        uint256 indexed jobId, 
        address indexed token, 
        uint256 amount
    );
    /// @notice Emitted when the client funds the job escrow
    event JobFunded(
        uint256 indexed jobId,
        address indexed client,
        uint256 amount
    );
    /// @notice Emitted when the provider submits a deliverable
    event JobSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        bytes32 deliverable
    );
    /// @notice Emitted when a job is completed (by evaluator)
    event JobCompleted(
        uint256 indexed jobId,
        address indexed evaluator,
        bytes32 reason
    );
    /// @notice Emitted when a job is rejected
    event JobRejected(
        uint256 indexed jobId,
        address indexed rejector,
        bytes32 reason
    );
    /// @notice Emitted when a job expires and transitions to Expired status
    event JobExpired(
        uint256 indexed jobId
    );
    /// @notice Emitted when the provider's net payment is released on completion
    event PaymentReleased(
        uint256 indexed jobId,
        address indexed provider,
        uint256 amount
    );
    /// @notice Emitted when the platform fee gets distributed on completion
    event PlatformFeePaid(
        uint256 indexed jobId,
        address indexed platformTreasury,
        uint256 amount
    );
    /// @notice Emitted when the evaluator fee is distributed on completion
    event EvaluatorFeePaid(
        uint256 indexed jobId,
        address indexed evaluator,
        uint256 amount
    );
    /// @notice Emitted when escrowed funds are returned to the client
    event Refunded(
        uint256 indexed jobId,
        address indexed client,
        uint256 amount
    );
    /// @notice Emitted on each successful partial settlement
    event Settled(
        uint256 indexed jobId,
        uint256 cumulativeAmount,
        uint256 delta
    );
    /// @notice Emitted on each successful submitClaim. Carries the work-evidence
    ///         deliverable so reputation systems and evaluators can index per-claim
    ///         work proof. In the fast (voucher) path the deliverable is bound by the
    ///         client's signature; in the slow path it is attested by approveClaim.
    event ClaimSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes deliverable
    );
    /// @notice Emitted when a pending claim is approved by evaluator or client.
    event ClaimApproved(
        uint256 indexed jobId,
        address indexed approver,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverableHash
    );
    /// @notice Emitted when a pending claim is rejected. Job remains open for
    ///         further submitClaim attempts by the provider.
    event ClaimRejected(
        uint256 indexed jobId,
        address indexed rejector,
        bytes32 reason
    );
    /// @notice Emitted when a hook's whitelist status changes
    event HookWhitelistUpdated(
        address indexed hook,
        bool status
    );
    /// @notice Emitted when a payment token's allowlist status changes
    event PaymentTokenAllowlistUpdated(
        address indexed token,
        bool status
    );
    /// @notice Emitted when admin detaches a hook from a specific job
    event HookDetached(
        uint256 indexed jobId, 
        address indexed hook
    );
    /// @notice Emitted when the platform fee or treasury is updated
    event PlatformFeeUpdated(
        uint256 feeBP, 
        address indexed treasury
    );
    /// @notice Emitted when the evaluator fee is updated
    event EvaluatorFeeUpdated(
        uint256 feeBP
    );
    /// @notice Emitted when admin performs an emergency withdrawal while paused
    event EmergencyWithdraw(
        address indexed token, 
        address indexed to, 
        uint256 amount
    );

    /// @notice Thrown when the job ID does not exist
    error InvalidJob();
    /// @notice Thrown when the hook does not support interface IERC8183Hook
    error InvalidHook();
    /// @notice Thrown when the job is not in a valid status for the requested action
    error WrongStatus();
    /// @notice Thrown when the caller is not authorized for the requested action
    error Unauthorized();
    /// @notice Thrown when a required address parameter is address(0)
    error ZeroAddress();
    /// @notice Thrown when the job expiry is too soon (must be > 5 minutes from now)
    error ExpiryTooShort();
    /// @notice Thrown when funding a job that has no provider assigned
    error ProviderNotSet();
    /// @notice Thrown when combined platform + evaluator fees exceed 100%
    error FeesTooHigh();
    /// @notice Thrown when a non-whitelisted hook is used in job creation
    error HookNotWhitelisted();
    /// @notice Thrown when the client's expectedBudget does not match the stored budget
    error BudgetMismatch();
    /// @notice Thrown when the evaluator and provider are the same address
    error ProviderCannotBeEvaluator();
    /// @notice Thrown when the client and provider are the same address
    error ClientCannotBeProvider();
    /// @notice Thrown when the job is expired with SUBMITTED status but block.timestamp < job.submittedAt + EVALUATION_GRACE_PERIOD
    error GracePeriodActive();
    /// @notice Thrown when the payment token is not on the allowlist
    error PaymentTokenNotAllowed();
    /// @notice Thrown when funded amount received differs from expected (fee-on-transfer / rebasing tokens)
    error UnexpectedFundedAmount();
    /// @notice Thrown when a Voucher signature does not match the client
    error InvalidVoucherSignature();
    /// @notice Thrown when a settle voucher does not advance the cumulative amount
    error NoNewSettlement();
    /// @notice Thrown when cumulative settlement would exceed the job budget
    error ExceedsBudget();
    /// @notice Thrown when submitting a new slow-path claim while one is already pending
    error ClaimAlreadyPending();
    /// @notice Thrown when approveClaim/rejectClaim is called with no pending claim
    error NoPendingClaim();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy with treasury and admin
    function initialize(address treasury_, address admin_) public initializer {
        if (treasury_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __EIP712_init(EIP712_NAME, EIP712_VERSION);
        platformTreasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        whitelistedHooks[address(0)] = true;
    }

    /// @notice Authorize contract upgrades, restricted to DEFAULT_ADMIN_ROLE
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ──────────────────── Admin ────────────────────

    /// @notice Pauses all user-facing lifecycle functions
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses all user-facing lifecycle functions
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdraw while the contract is paused
    ///         Pass token = address(0) for native ETH, otherwise ERC-20.
    /// @param token ERC-20 token address, or address(0) for native ETH
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "Transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit EmergencyWithdraw(token, to, amount);
    }

    /// @notice Updates the platform fee and treasury address
    /// @param feeBP_ New platform fee in basis points
    /// @param treasury_ New treasury address
    function setPlatformFee(
        uint256 feeBP_,
        address treasury_
    ) external onlyRole(ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBP_ + evaluatorFeeBP > 10000) revert FeesTooHigh();
        platformFeeBP = feeBP_;
        platformTreasury = treasury_;
        emit PlatformFeeUpdated(feeBP_, treasury_);
    }

    /// @notice Updates the evaluator fee
    /// @param feeBP_ New evaluator fee in basis points
    function setEvaluatorFee(uint256 feeBP_) external onlyRole(ADMIN_ROLE) {
        if (feeBP_ + platformFeeBP > 10000) revert FeesTooHigh();
        evaluatorFeeBP = feeBP_;
        emit EvaluatorFeeUpdated(feeBP_);
    }

    /// @notice Whitelist or remove a hook contract
    /// @dev    Whitelisted addresses serve two roles:
    ///         1. They can be set as the hook on new jobs (checked in createJob).
    ///         2. They can call beforeAction/afterAction on OTHER whitelisted hooks
    ///            (checked in BaseACPHook.onlyACP). This enables routers that
    ///            fan out to sub-hooks, but it also means every whitelisted address
    ///            gains cross-invocation power over all other hooks. Only whitelist
    ///            contracts you fully trust and have audited.
    /// @param hook The hook contract address
    /// @param status True to whitelist, false to remove
    function setHookWhitelist(
        address hook,
        bool status
    ) external onlyRole(ADMIN_ROLE) {
        if (hook == address(0)) revert ZeroAddress();
        whitelistedHooks[hook] = status;
        emit HookWhitelistUpdated(hook, status);
    }

    /// @notice Allow or revoke an ERC-20 token as a valid payment token.
    /// @dev    Tokens with non-standard semantics — fee-on-transfer, rebasing,
    ///         ERC-777/ERC-1363 transfer hooks, pausable/blacklist behavior — break
    ///         the escrow accounting in this contract. Only allow tokens you have
    ///         verified to behave as plain ERC-20 transfers.
    /// @param token  The ERC-20 token address
    /// @param status True to allow, false to revoke
    function setPaymentTokenAllowed(
        address token,
        bool status
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentTokens[token] = status;
        emit PaymentTokenAllowlistUpdated(token, status);
    }

    /// @notice Detach hooks from specific jobs. Admin emergency tool for
    ///         dewhitelisted hooks still attached to in-flight jobs.
    ///         Once detached, the job behaves like vanilla ERC-8183 (no gating, no bookkeeping).
    /// @param jobIds Array of job IDs to detach hooks from
    function batchDetachHook(uint256[] calldata jobIds) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < jobIds.length; i++) {
            uint256 jobId = jobIds[i];
            if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
            Job storage job = jobs[jobId];
            address oldHook = job.hook;
            if (oldHook == address(0)) continue;
            job.hook = address(0);
            emit HookDetached(jobId, oldHook);
        }
    }

    // ──────────────────── Hook Helpers ────────────────────

    /// @dev Calls beforeAction on the hook if one is attached. No-op when hook == address(0).
    function _beforeHook(
        address hook,
        uint256 jobId,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook != address(0)) {
            IERC8183Hook(hook).beforeAction(jobId, selector, data);
        }
    }

    /// @dev Calls afterAction on the hook if one is attached. No-op when hook == address(0).
    function _afterHook(
        address hook,
        uint256 jobId,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook != address(0)) {
            IERC8183Hook(hook).afterAction(jobId, selector, data);
        }
    }

    // ──────────────────── Job Lifecycle ────────────────────

    /// @notice Creates a new job. Client is msg.sender.
    //// @param provider Service provider (can be address(0) to assign later via setProvider)
    /// @param evaluator Third-party attestor (cannot be address(0))
    /// @param expiredAt Unix timestamp when the job expires (must be > 5 min from now)
    /// @param description Human-readable job description
    /// @param hook Hook contract address (address(0) = no hook, must be whitelisted)
    /// @param providerAgentId Optional ERC-8004 agent identity for provider
    /// @return The new job ID
    function createJob(
        address provider,
        address evaluator,
        uint48 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        if (msg.sender == provider) revert ClientCannotBeProvider();
        if (evaluator == address(0)) revert ZeroAddress();
        if (evaluator != address(0) && evaluator == provider) revert ProviderCannotBeEvaluator();
        if (!whitelistedHooks[hook]) revert HookNotWhitelisted();
        if (hook != address(0)) {
            if (
                !ERC165Checker.supportsInterface(
                    hook,
                    type(IERC8183Hook).interfaceId
                )
            ) revert InvalidHook();
        }

        uint256 jobId = ++jobCounter;
        jobs[jobId] = Job({
            client: msg.sender,
            status: JobStatus.Open,
            provider: provider,
            expiredAt: expiredAt,
            evaluator: evaluator,
            submittedAt: 0,
            budget: 0,
            settledAmount: 0,
            hook: hook,
            paymentToken: address(0),
            providerAgentId: provider != address(0) ? providerAgentId : 0,
            description: description
        });

        emit JobCreated(
            jobId,
            msg.sender,
            provider,
            evaluator,
            expiredAt,
            hook
        );

        return jobId;
    }

    /// @notice Assigns a provider to an Open job that has no provider yet. Client only.
    /// @param jobId The job to assign a provider to
    /// @param provider_ The provider address
    function setProvider(uint256 jobId, address provider_, uint256 agentId) external whenNotPaused {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert WrongStatus();
        if (provider_ == address(0)) revert ZeroAddress();
        if (provider_ == job.evaluator) revert ProviderCannotBeEvaluator();
        job.provider = provider_;
        job.providerAgentId = agentId;
        emit ProviderSet(jobId, provider_, agentId);
    }

    /// @notice Provider sets or updates the job budget. Can be called multiple times while Open and not expired.
    /// @param jobId The job to set the budget for
    /// @param token ERC-20 token used for job payment
    /// @param amount Budget amount in paymentToken units
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function setBudget(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();
        if (token == address(0)) revert ZeroAddress();
        if (!allowedPaymentTokens[token]) revert PaymentTokenNotAllowed();

        bytes memory data = abi.encode(msg.sender, token, amount, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.paymentToken = token;
        job.budget = amount;
        emit BudgetSet(jobId, token, amount);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    /// @notice Client funds the job escrow. Transitions Open -> Funded.
    /// @param jobId The job to fund
    /// @param expectedBudget Must match the stored budget (prevents front-running)
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function fund(
        uint256 jobId,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (job.budget != expectedBudget) revert BudgetMismatch();

        bytes memory data = abi.encode(msg.sender, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.status = JobStatus.Funded;
        if (job.budget > 0) {
            IERC20 token = IERC20(job.paymentToken);
            // Snapshot balance and assert delta == budget after transfer to reject
            // fee-on-transfer and rebasing tokens that would leave escrow short.
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(job.client, address(this), job.budget);
            uint256 received = token.balanceOf(address(this)) - balanceBefore;
            if (received != job.budget) revert UnexpectedFundedAmount();
        }
        emit JobFunded(jobId, job.client, job.budget);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    /// @notice Provider submits work. Transitions Funded -> Submitted (with evaluator)
    /// @param jobId The job to submit work for
    /// @param deliverable Hash or reference to the deliverable
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function submit(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (
            job.status != JobStatus.Funded &&
            (job.status != JobStatus.Open || job.budget > 0) // Allow Open job with 0 budget to be submitted
        ) revert WrongStatus();
        if (job.expiredAt != 0 && block.timestamp >= job.expiredAt) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();

        bytes memory data = abi.encode(msg.sender, deliverable, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.status = JobStatus.Submitted;
        job.submittedAt = uint48(block.timestamp);
        emit JobSubmitted(jobId, job.provider, deliverable);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    /// @notice Evaluator approves the submission. Transitions Submitted -> Completed.
    ///         Distributes escrowed funds: platform fee, evaluator fee, net to provider.
    /// @param jobId The job to complete
    /// @param reason Evaluator's attestation reason
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function complete(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Submitted) revert WrongStatus();
        if (msg.sender != job.evaluator) revert Unauthorized();

        bytes memory data = abi.encode(msg.sender, reason, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.status = JobStatus.Completed;

        uint256 amount = job.budget - job.settledAmount;
        uint256 platformFee = (amount * platformFeeBP) / 10000;
        uint256 evalFee = (amount * evaluatorFeeBP) / 10000;
        uint256 net = amount - platformFee - evalFee;

        IERC20 token = IERC20(job.paymentToken);
        if (platformFee > 0) {
            token.safeTransfer(platformTreasury, platformFee);
            emit PlatformFeePaid(jobId, platformTreasury, platformFee);
        }
        if (evalFee > 0) {
            token.safeTransfer(job.evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, evalFee);
        }
        if (net > 0) {
            token.safeTransfer(job.provider, net);
            emit PaymentReleased(jobId, job.provider, net);
        }

        emit JobCompleted(jobId, job.evaluator, reason);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    /// @notice Rejects a job. Refunds escrowed funds to the client if applicable.
    /// @dev    Authorization depends on status and evaluator:
    ///         - Open: client or provider
    ///         - Funded/Submitted: evaluator only
    /// @param jobId The job to reject
    /// @param reason Rejection reason
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function reject(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();

        if (job.status == JobStatus.Open) {
            if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();
        } else if (
            job.status == JobStatus.Funded || job.status == JobStatus.Submitted
        ) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }

        bytes memory data = abi.encode(msg.sender, reason, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        JobStatus prev = job.status;
        job.status = JobStatus.Rejected;

        uint256 refundAmount = job.budget - job.settledAmount;
        if (
            (prev == JobStatus.Funded || prev == JobStatus.Submitted) &&
            refundAmount > 0
        ) {
            IERC20(job.paymentToken).safeTransfer(job.client, refundAmount);
            emit Refunded(jobId, job.client, refundAmount);
        }

        emit JobRejected(jobId, msg.sender, reason);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    /// @notice Claims a refund for an expired job. Anyone can call.
    ///         Transitions Open/Funded/Submitted -> Expired after expiry time.
    ///         Not hookable -- funds are always recoverable regardless of hook behavior.
    /// @param jobId The expired job to claim refund for
    function claimRefund(uint256 jobId) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open && job.status != JobStatus.Funded && job.status != JobStatus.Submitted)
            revert WrongStatus();
        if (job.status == JobStatus.Submitted) {
            if (block.timestamp < job.expiredAt + EVALUATION_GRACE_PERIOD) revert GracePeriodActive();
        } else {
            if (block.timestamp < job.expiredAt) revert WrongStatus();
        }

        JobStatus prev = job.status;
        job.status = JobStatus.Expired;

        uint256 refundAmount = job.budget - job.settledAmount;
        if (refundAmount > 0 && (prev == JobStatus.Funded || prev == JobStatus.Submitted)) {
            IERC20(job.paymentToken).safeTransfer(job.client, refundAmount);
            emit Refunded(jobId, job.client, refundAmount);
        }

        emit JobExpired(jobId);
    }

    // ──────────────────── Partial Settlement ────────────────────

    /// @dev Verifies an EIP-712 Voucher signature against the expected signer (client).
    function _verifyVoucher(
        uint256 jobId,
        uint256 cumulativeAmount,
        address expectedSigner,
        bytes calldata optParams,
        bytes calldata sig
    ) internal view {
        // Client signs over optParams to bind hook actions for partial settlement.
        bytes32 structHash = keccak256(
            abi.encode(
                VOUCHER_TYPEHASH,
                jobId,
                cumulativeAmount,
                keccak256(optParams)
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        if (
            !SignatureChecker.isValidSignatureNowCalldata(
                expectedSigner,
                digest,
                sig
            )
        ) revert InvalidVoucherSignature();
    }

    /// @dev Verifies an EIP-712 ClaimVoucher signature against the expected signer
    ///      (client). Binds the deliverable into the digest so the signature
    ///      attests to the work delivered, not just the amount released.
    function _verifyClaimVoucher(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes calldata deliverable,
        address expectedSigner,
        bytes calldata optParams,
        bytes calldata sig
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_VOUCHER_TYPEHASH,
                jobId,
                cumulativeAmount,
                keccak256(deliverable),
                keccak256(optParams)
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        if (
            !SignatureChecker.isValidSignatureNowCalldata(
                expectedSigner,
                digest,
                sig
            )
        ) revert InvalidVoucherSignature();
    }

    /// @notice Voucher-based partial settlement (Provider only).
    /// @dev    Verifies an EIP-712 Voucher signed by the client and releases only the new delta.
    ///         Incremental — does not close the job. Job remains Funded or Submitted.
    /// @param jobId            The job to settle
    /// @param cumulativeAmount Monotonically increasing cumulative gross amount
    /// @param voucherSig       EIP-712 Voucher signature from the client
    /// @param optParams        Hook-specific parameters, also bound into the voucher digest
    function settle(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes calldata voucherSig,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (msg.sender != job.provider) revert Unauthorized();
        if (
            job.status != JobStatus.Funded && job.status != JobStatus.Submitted
        ) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        _verifyVoucher(
            jobId,
            cumulativeAmount,
            job.client,
            optParams,
            voucherSig
        );

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory data = abi.encode(msg.sender, delta, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.settledAmount = cumulativeAmount;
        uint256 platformFee = (delta * platformFeeBP) / 10000;
        uint256 evalFee = (delta * evaluatorFeeBP) / 10000;
        uint256 net = delta - platformFee - evalFee;

        IERC20 token = IERC20(job.paymentToken);
        if (platformFee > 0) {
            token.safeTransfer(platformTreasury, platformFee);
            emit PlatformFeePaid(jobId, platformTreasury, platformFee);
        }
        if (evalFee > 0) {
            token.safeTransfer(job.evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, evalFee);
        }
        if (net > 0) {
            token.safeTransfer(job.provider, net);
        }
        emit PaymentReleased(jobId, job.provider, net);

        emit Settled(jobId, cumulativeAmount, delta);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    // ──────────────────── Claim Workflow ────────────────────

    /// @dev Shared fee/payment distribution used by claim settlement paths.
    function _distributeSettlement(
        uint256 jobId,
        Job storage job,
        uint256 delta
    ) internal {
        uint256 platformFee = (delta * platformFeeBP) / 10000;
        uint256 evalFee = (delta * evaluatorFeeBP) / 10000;
        uint256 net = delta - platformFee - evalFee;

        IERC20 token = IERC20(job.paymentToken);
        if (platformFee > 0) {
            token.safeTransfer(platformTreasury, platformFee);
            emit PlatformFeePaid(jobId, platformTreasury, platformFee);
        }
        if (evalFee > 0) {
            token.safeTransfer(job.evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, evalFee);
        }
        if (net > 0) {
            token.safeTransfer(job.provider, net);
        }
        emit PaymentReleased(jobId, job.provider, net);
    }

    /// @notice Unified claim submission (Provider only). Both fast and slow paths share
    ///         this entry point; the length of `deliverable` selects between them:
    ///           - `deliverable.length == 0`  → fast path: client signed an
    ///             unconditional payment authorization (no deliverable to vet).
    ///             The signature itself is the approval, so the new delta is
    ///             released in this same tx.
    ///           - `deliverable.length  > 0`  → slow path: the deliverable is a
    ///             specific condition the evaluator (or client) must vet against.
    ///             Stored as a pending claim; awaits `approveClaim` or `rejectClaim`.
    /// @dev    Both paths require an EIP-712 ClaimVoucher signed by the client and
    ///         submitted by the provider. Voucher binds (jobId, cumulativeAmount,
    ///         deliverable, optParams). Incremental — does not close the job.
    /// @param jobId            The job to claim against
    /// @param cumulativeAmount Monotonically increasing cumulative gross amount
    /// @param deliverable      Condition for the evaluator to vet. Empty = fast path
    ///                         (unconditional, immediate release); non-empty = slow
    ///                         path (pending approval).
    /// @param voucherSig       EIP-712 ClaimVoucher signature from the client
    /// @param optParams        Hook-specific parameters, also bound into the voucher digest
    function submitClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes calldata deliverable,
        bytes calldata voucherSig,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (msg.sender != job.provider) revert Unauthorized();
        if (
            job.status != JobStatus.Funded && job.status != JobStatus.Submitted
        ) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        // Both paths verify the client's signature over the same voucher struct.
        _verifyClaimVoucher(
            jobId,
            cumulativeAmount,
            deliverable,
            job.client,
            optParams,
            voucherSig
        );

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory data = abi.encode(msg.sender, delta, deliverable, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        if (deliverable.length == 0) {
            // ── Fast path ──
            // No deliverable condition to vet. The client's signature is an
            // unconditional release authorization, so settle in the same tx.
            // Voucher supersedes any pending slow-path claim.
            if (pendingClaimHash[jobId] != bytes32(0)) {
                delete pendingClaimHash[jobId];
            }
            job.settledAmount = cumulativeAmount;
            _distributeSettlement(jobId, job, delta);
            emit Settled(jobId, cumulativeAmount, delta);
            emit ClaimSubmitted(jobId, job.provider, cumulativeAmount, delta, deliverable);
        } else {
            // ── Slow path ──
            // Deliverable is a specific condition the evaluator/client must vet.
            // Only the hash binding (amount, deliverableHash) is stored to keep
            // pending state to one slot; the full deliverable bytes are emitted
            // via ClaimSubmitted so approvers can read it from event logs.
            if (pendingClaimHash[jobId] != bytes32(0)) revert ClaimAlreadyPending();
            pendingClaimHash[jobId] = _claimHash(cumulativeAmount, keccak256(deliverable));
            emit ClaimSubmitted(jobId, job.provider, cumulativeAmount, delta, deliverable);
        }

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    /// @dev Recomputes the pending-claim binding hash from its components.
    function _claimHash(
        uint256 cumulativeAmount,
        bytes32 deliverableHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(cumulativeAmount, deliverableHash));
    }

    /// @notice Approves the pending slow-path claim for a job. Client or evaluator.
    /// @dev    Caller supplies `cumulativeAmount` + `deliverableHash` (preimage of the
    ///         stored binding hash). Contract recomputes the hash and rejects any
    ///         mismatch, so approvers cannot release funds for a claim other than
    ///         the one the provider committed to. Releases the delta and clears
    ///         the pending claim.
    /// @param jobId            The job whose pending claim to approve
    /// @param cumulativeAmount Claim amount the provider committed (read from ClaimSubmitted)
    /// @param deliverableHash  keccak256(deliverable) the provider committed (read from event)
    /// @param optParams        Hook-specific parameters
    function approveClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverableHash,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (msg.sender != job.client && msg.sender != job.evaluator) revert Unauthorized();
        if (
            job.status != JobStatus.Funded && job.status != JobStatus.Submitted
        ) revert WrongStatus();

        bytes32 stored = pendingClaimHash[jobId];
        if (stored == bytes32(0)) revert NoPendingClaim();
        if (stored != _claimHash(cumulativeAmount, deliverableHash)) revert NoPendingClaim();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory data = abi.encode(msg.sender, delta, deliverableHash, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        delete pendingClaimHash[jobId];
        job.settledAmount = cumulativeAmount;
        _distributeSettlement(jobId, job, delta);

        emit Settled(jobId, cumulativeAmount, delta);
        emit ClaimApproved(jobId, msg.sender, cumulativeAmount, delta, deliverableHash);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    /// @notice Rejects the pending slow-path claim for a job. Client or evaluator.
    /// @dev    Caller supplies the claim preimage components for hash verification,
    ///         same as approveClaim. Clears the pending claim without releasing funds;
    ///         the provider can submit a revised claim afterwards. Use `reject` to
    ///         terminate the job entirely.
    /// @param jobId            The job whose pending claim to reject
    /// @param cumulativeAmount Claim amount being rejected
    /// @param deliverableHash  keccak256(deliverable) being rejected
    /// @param reason           Rejection reason (bytes32 tag)
    /// @param optParams        Hook-specific parameters
    function rejectClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverableHash,
        bytes32 reason,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (msg.sender != job.client && msg.sender != job.evaluator) revert Unauthorized();
        if (
            job.status != JobStatus.Funded && job.status != JobStatus.Submitted
        ) revert WrongStatus();

        bytes32 stored = pendingClaimHash[jobId];
        if (stored == bytes32(0)) revert NoPendingClaim();
        if (stored != _claimHash(cumulativeAmount, deliverableHash)) revert NoPendingClaim();

        bytes memory data = abi.encode(msg.sender, reason, deliverableHash, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        delete pendingClaimHash[jobId];

        emit ClaimRejected(jobId, msg.sender, reason);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    // ──────────────────── View ────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }
}

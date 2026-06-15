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
import "./IDisburser.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

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

    /// @notice Core job data, with new fields appended to preserve storage layout
    /// @param client           Job creator who funds the escrow
    /// @param status           Current lifecycle state
    /// @param provider         Service provider who delivers work
    /// @param expiredAt        Unix timestamp after which the job can be expired
    /// @param evaluator        Third-party attestor
    /// @param submittedAt      Unix timestamp when provider submitted work
    /// @param budget           Escrowed payment amount in paymentToken units
    /// @param hook             Hook contract for before/after callbacks (address(0) = no hook)
    /// @param paymentToken     ERC-20 token used for job payment
    /// @param providerAgentId  Optional ERC-8004 agent identity for provider
    /// @param description      Human-readable job description
    /// @param settledAmount    Cumulative gross amount released via claim settlements
    /// @param payoutReceiver   Provider-side payout receiver (address(0) = pay provider directly)
    struct Job {
        address client;             // 20 ──┐ slot 1
        JobStatus status;           // 1  ──┘
        address provider;           // 20 ──┐ slot 2
        uint48 expiredAt;           // 6  ──┘
        address evaluator;          // 20 ──┐ slot 3
        uint48 submittedAt;         // 6  ──┘ 
        uint256 budget;             // 32 ──  slot 4
        address hook;               // 20 ──  slot 5
        address paymentToken;       // 20 ──  slot 6
        uint256 providerAgentId;    // 32 ──  slot 7
        string description;         //        slot 8+
        uint256 settledAmount;      // 32 ──  slot 9
        address payoutReceiver;     // 20 ──  slot 10
    }

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    string internal constant EIP712_NAME = "ERC8183";
    string internal constant EIP712_VERSION = "1";

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
    /// @notice Monotonically increasing job ID counter
    uint256 public jobCounter;
    /// @notice Hook address -> whether it is whitelisted for use
    mapping(address => bool) public whitelistedHooks;
    /// @notice ERC-20 token -> whether it is allowed as a payment token
    /// @dev    Allowlist enforces that only tokens with vetted ERC-20 semantics
    ///         (no fee-on-transfer, no rebase, no transfer hooks, no pause/blacklist
    ///         that would lock escrowed funds) can be used for job budgets.
    mapping(address => bool) public allowedPaymentTokens;
    /// @notice Job ID -> hash binding the pending nonzero-deliverable claim.
    mapping(uint256 => bytes32) public pendingClaimHash;
    /// @notice Job ID -> claim hash -> whether the claim hash has already been submitted.
    mapping(uint256 => mapping(bytes32 => bool)) public submittedClaimHash;

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
        address indexed actor,
        address indexed provider,
        uint256 agentId
    );
    /// @notice Emitted when the payout receiver for a job is set or updated
    event PayoutReceiverSet(
        uint256 indexed jobId,
        address indexed actor,
        address indexed payoutReceiver
    );
    /// @notice Emitted when onDisbursement is invoked for a receiver that advertises IDisburser
    event Disbursed(
        uint256 indexed jobId,
        address indexed receiver,
        bytes4 selector,
        uint256 amount
    );
    /// @notice Emitted when the provider sets or updates the job budget
    event BudgetSet(
        uint256 indexed jobId,
        address indexed actor,
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
    /// @notice Emitted when the provider's net payment is released
    event PaymentReleased(
        uint256 indexed jobId,
        address indexed recipient,
        uint256 amount
    );
    /// @notice Emitted when the platform fee gets distributed
    event PlatformFeePaid(
        uint256 indexed jobId,
        address indexed platformTreasury,
        uint256 amount
    );
    /// @notice Emitted when the evaluator fee is distributed
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
    /// @notice Emitted when a provider submits a claim against a funded job
    event ClaimSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverable,
        bytes optParams // Emitted so the exact claim preimage can be propagated to observers.
    );
    /// @notice Emitted when a client settles a claim directly
    /// @dev `deliverable` is the client's settlement attestation, not a verified
    ///      provider claim hash.
    event ClaimSettled(
        uint256 indexed jobId,
        address indexed settler,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverable
    );
    /// @notice Emitted when a pending claim is approved by the client or evaluator
    event ClaimApproved(
        uint256 indexed jobId,
        address indexed approver,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverable
    );
    /// @notice Emitted when a pending claim is rejected, withdrawn, or superseded
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
    /// @notice Thrown when the payout receiver would strand funds in this escrow
    error InvalidReceiver();
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
    /// @notice Thrown when the client's expected payment token does not match the stored payment token
    error PaymentTokenMismatch();
    /// @notice Thrown when the evaluator and provider are the same address
    error ProviderCannotBeEvaluator();
    /// @notice Thrown when the client and provider are the same address
    error ClientCannotBeProvider();
    /// @notice Thrown when a Submitted job is within the post-expiry evaluator grace period
    error GracePeriodActive();
    /// @notice Thrown when the payment token is not on the allowlist
    error PaymentTokenNotAllowed();
    /// @notice Thrown when funded amount received differs from expected (fee-on-transfer / rebasing tokens)
    error UnexpectedFundedAmount();
    /// @notice Thrown when a claim does not advance the cumulative amount
    error NoNewSettlement();
    /// @notice Thrown when cumulative settlement would exceed the job budget
    error ExceedsBudget();
    /// @notice Thrown when submitting a nonzero-deliverable claim hash that was already submitted
    error ClaimAlreadySubmitted();
    /// @notice Thrown when submitting a provider claim without a deliverable
    error EmptyDeliverable();
    /// @notice Thrown when submitting a provider claim or refunding while another claim is pending
    error PendingClaimExists();
    /// @notice Thrown when approveClaim/rejectClaim is called with no matching pending claim
    error NoPendingClaim();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy with treasury and admin
    function initialize(address treasury_, address admin_) public virtual initializer {
        __ERC8183_init(treasury_, admin_, EIP712_NAME, EIP712_VERSION);
    }

    function __ERC8183_init(
        address treasury_,
        address admin_,
        string memory eip712Name_,
        string memory eip712Version_
    ) internal onlyInitializing {
        if (treasury_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __EIP712_init(eip712Name_, eip712Version_);
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
    ///         2. Hook implementations may choose to trust whitelisted addresses
    ///            as cross-hook callers. This enables routers that fan out to
    ///            sub-hooks, but it also means every whitelisted address can gain
    ///            cross-invocation power if hooks opt into that trust model. Only
    ///            whitelist contracts you fully trust and have audited.
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

    /// @dev Only receivers with deployed code can receive the optional callback.
    ///      EOAs and contracts that do not advertise IDisburser are plain recipients.
    function _isDisburser(address receiver) internal view returns (bool) {
        return receiver.code.length > 0 && ERC165Checker.supportsInterface(
            receiver,
            type(IDisburser).interfaceId
        );
    }

    function _payout(
        uint256 jobId,
        Job storage job,
        uint256 net,
        bytes4 selector,
        bytes calldata optParams
    ) internal {
        address recipient = job.payoutReceiver == address(0) ? job.provider : job.payoutReceiver;
        if (net > 0) {
            IERC20(job.paymentToken).safeTransfer(recipient, net);
            emit PaymentReleased(jobId, recipient, net);

            if (_isDisburser(recipient)) {
                IDisburser(recipient).onDisbursement(
                    jobId,
                    selector,
                    job.paymentToken,
                    net,
                    optParams
                );
                emit Disbursed(jobId, recipient, selector, net);
            }
        }
    }

    function _validatePayoutReceiver(address payoutReceiver, address paymentToken) internal view {
        if (payoutReceiver == address(this)) revert InvalidReceiver();
        if (payoutReceiver != address(0) && payoutReceiver == paymentToken) revert InvalidReceiver();
    }

    // ──────────────────── Job Lifecycle ────────────────────

    /// @notice Creates a new job. Client is msg.sender.
    /// @param provider Service provider (can be address(0) to assign later via setProvider)
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
        uint256 providerAgentId,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant returns (uint256) {
        return _createJob(msg.sender, provider, evaluator, expiredAt, description, hook, providerAgentId, optParams);
    }

    function _createJob(
        address client,
        address provider,
        address evaluator,
        uint48 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId,
        bytes calldata optParams
    ) internal returns (uint256) {
        if (client == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        if (client == provider) revert ClientCannotBeProvider();
        if (evaluator == address(0)) revert ZeroAddress();
        if (evaluator == provider) revert ProviderCannotBeEvaluator();
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
            client: client,
            status: JobStatus.Open,
            provider: provider,
            expiredAt: expiredAt,
            evaluator: evaluator,
            submittedAt: 0,
            budget: 0,
            hook: hook,
            paymentToken: address(0),
            // A providerless job has no provider to attribute, so its agent id is zero.
            providerAgentId: provider != address(0) ? providerAgentId : 0,
            description: description,
            settledAmount: 0,
            payoutReceiver: address(0)
        });

        emit JobCreated(
            jobId,
            client,
            provider,
            evaluator,
            expiredAt,
            hook
        );

        // afterAction only: the hook is now attached and the job exists, so it can
        // initialize per-job bookkeeping or revert to reject a job it will not service.
        // No beforeAction — there is no attached hook before creation, and attachment
        // is already gated by the whitelist + ERC-165 check above.
        // The payload reads providerAgentId back from storage so the hook never sees an
        // agent id that disagrees with jobs[jobId] (e.g. a providerless job canonicalizes to 0).
        _afterHook(
            hook,
            jobId,
            this.createJob.selector,
            abi.encode(client, provider, evaluator, expiredAt, hook, jobs[jobId].providerAgentId, optParams)
        );

        return jobId;
    }

    /// @notice Provider updates the payout receiver while the job is still Open.
    ///         Locked once the job is funded.
    /// @param jobId The job to update
    /// @param payoutReceiver New payout receiver (address(0) = pay provider directly)
    function setPayoutReceiver(uint256 jobId, address payoutReceiver, bytes calldata optParams)
        external
        whenNotPaused
        nonReentrant
    {
        _setPayoutReceiver(msg.sender, jobId, payoutReceiver, optParams);
    }

    function _setPayoutReceiver(
        address actor,
        uint256 jobId,
        address payoutReceiver,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (actor != job.provider) revert Unauthorized();
        _validatePayoutReceiver(payoutReceiver, job.paymentToken);

        bytes memory data = abi.encode(actor, payoutReceiver, optParams);
        _beforeHook(job.hook, jobId, this.setPayoutReceiver.selector, data);

        job.payoutReceiver = payoutReceiver;
        emit PayoutReceiverSet(jobId, actor, payoutReceiver);

        _afterHook(job.hook, jobId, this.setPayoutReceiver.selector, data);
    }

    /// @notice Assigns a provider to an Open job that has no provider yet. Client only.
    /// @param jobId The job to assign a provider to
    /// @param provider_ The provider address
    function setProvider(uint256 jobId, address provider_, uint256 agentId, bytes calldata optParams)
        external
        whenNotPaused
        nonReentrant
    {
        _setProvider(msg.sender, jobId, provider_, agentId, optParams);
    }

    function _setProvider(
        address actor,
        uint256 jobId,
        address provider_,
        uint256 agentId,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (actor != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert WrongStatus();
        if (provider_ == address(0)) revert ZeroAddress();
        if (provider_ == job.client) revert ClientCannotBeProvider();
        if (provider_ == job.evaluator) revert ProviderCannotBeEvaluator();

        bytes memory data = abi.encode(actor, provider_, agentId, optParams);
        _beforeHook(job.hook, jobId, this.setProvider.selector, data);

        job.provider = provider_;
        job.providerAgentId = agentId;
        emit ProviderSet(jobId, actor, provider_, agentId);

        _afterHook(job.hook, jobId, this.setProvider.selector, data);
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
        _setBudget(msg.sender, jobId, token, amount, optParams);
    }

    function _setBudget(
        address actor,
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (actor != job.provider) revert Unauthorized();
        if (token == address(0)) revert ZeroAddress();
        if (!allowedPaymentTokens[token]) revert PaymentTokenNotAllowed();
        _validatePayoutReceiver(job.payoutReceiver, token);

        bytes memory data = abi.encode(actor, token, amount, optParams);
        _beforeHook(job.hook, jobId, this.setBudget.selector, data);

        job.paymentToken = token;
        job.budget = amount;
        emit BudgetSet(jobId, actor, token, amount);

        _afterHook(job.hook, jobId, this.setBudget.selector, data);
    }

    /// @notice Client funds the job escrow. Transitions Open -> Funded.
    /// @param jobId The job to fund
    /// @param expectedToken Must match the stored payment token (prevents token-swap front-running)
    /// @param expectedBudget Must match the stored budget (prevents front-running)
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function fund(
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _fund(msg.sender, jobId, expectedToken, expectedBudget, optParams);
    }

    function _fund(
        address actor,
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (actor != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (job.paymentToken != expectedToken) revert PaymentTokenMismatch();
        if (job.budget != expectedBudget) revert BudgetMismatch();

        bytes memory data = abi.encode(actor, optParams);
        _beforeHook(job.hook, jobId, this.fund.selector, data);

        job.status = JobStatus.Funded;
        if (job.budget > 0) {
            IERC20 token = IERC20(job.paymentToken);
            // Snapshot balance and assert delta == budget after transfer to reject
            // fee-on-transfer and rebasing tokens that would leave escrow short.
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(actor, address(this), job.budget);
            uint256 received = token.balanceOf(address(this)) - balanceBefore;
            if (received != job.budget) revert UnexpectedFundedAmount();
        }
        emit JobFunded(jobId, actor, job.budget);

        _afterHook(job.hook, jobId, this.fund.selector, data);
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
        _submit(msg.sender, jobId, deliverable, optParams);
    }

    function _submit(
        address actor,
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (
            job.status != JobStatus.Funded &&
            (job.status != JobStatus.Open || job.budget > 0) // Allow Open job with 0 budget to be submitted
        ) revert WrongStatus();
        if (job.expiredAt != 0 && block.timestamp >= job.expiredAt) revert WrongStatus();
        if (actor != job.provider) revert Unauthorized();

        bytes memory data = abi.encode(actor, deliverable, optParams);
        if (pendingClaimHash[jobId] != bytes32(0)) {
            // Final submit supersedes any pending milestone claim: the provider is
            // moving to the normal completion path for the full remaining escrow,
            // and submit hooks should observe that post-supersede claim state.
            delete pendingClaimHash[jobId];
            emit ClaimRejected(jobId, actor, bytes32("superseded-by-submit"));
        }
        _beforeHook(job.hook, jobId, this.submit.selector, data);

        job.status = JobStatus.Submitted;
        // forge-lint: disable-next-line(unsafe-typecast)
        job.submittedAt = uint48(block.timestamp);
        emit JobSubmitted(jobId, actor, deliverable);

        _afterHook(job.hook, jobId, this.submit.selector, data);
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
        _complete(msg.sender, jobId, reason, optParams);
    }

    function _complete(
        address actor,
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Submitted) revert WrongStatus();
        if (actor != job.evaluator) revert Unauthorized();

        bytes memory data = abi.encode(actor, reason, optParams);
        _beforeHook(job.hook, jobId, this.complete.selector, data);

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
        _payout(jobId, job, net, this.complete.selector, optParams);

        emit JobCompleted(jobId, actor, reason);

        _afterHook(job.hook, jobId, this.complete.selector, data);
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
        _reject(msg.sender, jobId, reason, optParams);
    }

    function _reject(
        address actor,
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();

        if (job.status == JobStatus.Open) {
            if (actor != job.client && actor != job.provider) revert Unauthorized();
        } else if (
            job.status == JobStatus.Funded || job.status == JobStatus.Submitted
        ) {
            if (actor != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }

        bytes memory data = abi.encode(actor, reason, optParams);
        if (pendingClaimHash[jobId] != bytes32(0)) {
            // Terminal job rejection also rejects any pending milestone claim, so
            // hooks and indexers observe a closed claim lifecycle.
            delete pendingClaimHash[jobId];
            emit ClaimRejected(jobId, actor, reason);
        }
        _beforeHook(job.hook, jobId, this.reject.selector, data);

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

        emit JobRejected(jobId, actor, reason);

        _afterHook(job.hook, jobId, this.reject.selector, data);
    }

    /// @notice Claims a refund for an expired job. Anyone can call.
    ///         Transitions Open/Funded/Submitted -> Expired after expiry time.
    ///         Pending claims must still be resolved before refund.
    /// @dev    Hookable: the attached hook's before/after callbacks fire around the
    ///         refund and MAY revert. Because this is the permissionless escrow
    ///         recovery path, a misbehaving hook that reverts can block the refund
    ///         and lock escrowed funds. Mitigations: hooks are admin-whitelisted and
    ///         ERC-165-checked at attach time, and an admin can sever a bad hook from
    ///         in-flight jobs via batchDetachHook (after which claimRefund succeeds).
    /// @param jobId The expired job to claim refund for
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function claimRefund(uint256 jobId, bytes calldata optParams) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open && job.status != JobStatus.Funded && job.status != JobStatus.Submitted)
            revert WrongStatus();
        bool hasPendingClaim = pendingClaimHash[jobId] != bytes32(0);
        if (job.status == JobStatus.Submitted) {
            if (block.timestamp < job.expiredAt + EVALUATION_GRACE_PERIOD) revert GracePeriodActive();
        } else if (hasPendingClaim) {
            revert PendingClaimExists();
        } else {
            if (block.timestamp < job.expiredAt) revert WrongStatus();
        }

        bytes memory data = abi.encode(msg.sender, optParams);
        _beforeHook(job.hook, jobId, this.claimRefund.selector, data);

        JobStatus prev = job.status;
        job.status = JobStatus.Expired;

        uint256 refundAmount = job.budget - job.settledAmount;
        if (refundAmount > 0 && (prev == JobStatus.Funded || prev == JobStatus.Submitted)) {
            IERC20(job.paymentToken).safeTransfer(job.client, refundAmount);
            emit Refunded(jobId, job.client, refundAmount);
        }

        emit JobExpired(jobId);

        _afterHook(job.hook, jobId, this.claimRefund.selector, data);
    }

    function _distributeSettlement(
        uint256 jobId,
        Job storage job,
        uint256 delta,
        bytes4 selector,
        bytes calldata optParams
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
        _payout(jobId, job, net, selector, optParams);
    }

    function _claimHash(
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 optParamsHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(cumulativeAmount, deliverable, optParamsHash));
    }

    /// @notice Provider submits a pending claim against a funded job.
    function submitClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _submitClaim(msg.sender, jobId, cumulativeAmount, deliverable, optParams);
    }

    function _submitClaim(
        address actor,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (actor != job.provider) revert Unauthorized();
        if (job.status != JobStatus.Funded) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (deliverable == bytes32(0)) revert EmptyDeliverable();
        if (pendingClaimHash[jobId] != bytes32(0)) revert PendingClaimExists();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory data = abi.encode(actor, cumulativeAmount, deliverable, optParams);
        _beforeHook(job.hook, jobId, this.submitClaim.selector, data);

        bytes32 claimHash = _claimHash(cumulativeAmount, deliverable, keccak256(optParams));
        if (submittedClaimHash[jobId][claimHash]) revert ClaimAlreadySubmitted();
        submittedClaimHash[jobId][claimHash] = true;
        pendingClaimHash[jobId] = claimHash;

        emit ClaimSubmitted(jobId, actor, cumulativeAmount, delta, deliverable, optParams);
        _afterHook(job.hook, jobId, this.submitClaim.selector, data);
    }

    /// @notice Client settles a claim immediately against a funded job.
    function settleClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _settleClaim(msg.sender, jobId, cumulativeAmount, deliverable, optParams);
    }

    function _settleClaim(
        address actor,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (actor != job.client) revert Unauthorized();
        if (job.status != JobStatus.Funded) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory data = abi.encode(actor, cumulativeAmount, deliverable, optParams);
        _beforeHook(job.hook, jobId, this.settleClaim.selector, data);

        job.settledAmount = cumulativeAmount;
        _distributeSettlement(jobId, job, delta, this.settleClaim.selector, optParams);

        emit Settled(jobId, cumulativeAmount, delta);
        emit ClaimSettled(jobId, actor, cumulativeAmount, delta, deliverable);

        _afterHook(job.hook, jobId, this.settleClaim.selector, data);
    }

    /// @notice Client or evaluator approves a pending nonzero-deliverable claim.
    function approveClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _approveClaim(msg.sender, jobId, cumulativeAmount, deliverable, optParams);
    }

    function _approveClaim(
        address actor,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (actor != job.client && actor != job.evaluator) revert Unauthorized();
        if (job.status != JobStatus.Funded) revert WrongStatus();

        bytes32 stored = pendingClaimHash[jobId];
        if (stored == bytes32(0)) revert NoPendingClaim();
        if (stored != _claimHash(cumulativeAmount, deliverable, keccak256(optParams))) revert NoPendingClaim();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory data = abi.encode(actor, cumulativeAmount, deliverable, optParams);
        _beforeHook(job.hook, jobId, this.approveClaim.selector, data);

        delete pendingClaimHash[jobId];
        job.settledAmount = cumulativeAmount;
        _distributeSettlement(jobId, job, delta, this.approveClaim.selector, optParams);

        emit Settled(jobId, cumulativeAmount, delta);
        emit ClaimApproved(jobId, actor, cumulativeAmount, delta, deliverable);

        _afterHook(job.hook, jobId, this.approveClaim.selector, data);
    }

    /// @notice Client/evaluator rejects a pending claim, or provider withdraws their own pending claim.
    function rejectClaim(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 reason,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _rejectClaim(msg.sender, jobId, cumulativeAmount, deliverable, reason, optParams);
    }

    function _rejectClaim(
        address actor,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 reason,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        // The provider may self-cancel a stale claim to unblock a corrected claim.
        if (actor != job.client && actor != job.evaluator && actor != job.provider) revert Unauthorized();
        if (job.status != JobStatus.Funded) revert WrongStatus();

        bytes32 stored = pendingClaimHash[jobId];
        if (stored == bytes32(0)) revert NoPendingClaim();
        if (stored != _claimHash(cumulativeAmount, deliverable, keccak256(optParams))) revert NoPendingClaim();

        bytes memory data = abi.encode(actor, cumulativeAmount, deliverable, reason, optParams);
        _beforeHook(job.hook, jobId, this.rejectClaim.selector, data);

        // Keep submittedClaimHash consumed; callers must change cumulative amount, deliverable, or optParams to refile.
        delete pendingClaimHash[jobId];
        emit ClaimRejected(jobId, actor, reason);

        _afterHook(job.hook, jobId, this.rejectClaim.selector, data);
    }

    // ──────────────────── View ────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }
}

// SPDX-License-Identifier: MIT
// ERC-8183: Agentic Commerce Protocol — Reference Implementation
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "./IACPHook.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

/**
 * @title AgenticCommerce
 * @dev Reference implementation of ERC-8183: Agentic Commerce Protocol.
 *      Implements a job escrow state machine with optional hook extension points.
 *      Core state machine: Open -> Funded -> Submitted -> Completed | Rejected | Expired.
 *
 *      Hooks (IACPHook):
 *        before* — called BEFORE state change, CAN revert to gate the transition.
 *        after*  — called AFTER state change for bookkeeping/side effects.
 *
 *      When hook == address(0), the contract operates as a standalone job escrow.
 */
contract AgenticCommerce is Initializable, AccessControlUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        address hook;
        address paymentToken;
        uint256 providerAgentId; // Optional ERC-8004 agent identity
    }

    uint256 public platformFeeBP; // 10000 = 100%
    address public platformTreasury;
    uint256 public evaluatorFeeBP;

    mapping(uint256 => Job) public jobs;
    uint256 public jobCounter;
    mapping(address => bool) public whitelistedHooks;
    mapping(uint256 jobId => bool hasBudget) public jobHasBudget;

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        uint256 expiredAt,
        address hook
    );
    event ProviderSet(uint256 indexed jobId, address indexed provider, uint256 agentId);
    event BudgetSet(uint256 indexed jobId, address indexed token, uint256 amount);
    event JobFunded(
        uint256 indexed jobId,
        address indexed client,
        uint256 amount
    );
    event JobSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        bytes32 deliverable
    );
    event JobCompleted(
        uint256 indexed jobId,
        address indexed evaluator,
        bytes32 reason
    );
    event JobRejected(
        uint256 indexed jobId,
        address indexed rejector,
        bytes32 reason
    );
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(
        uint256 indexed jobId,
        address indexed provider,
        uint256 amount
    );
    event EvaluatorFeePaid(
        uint256 indexed jobId,
        address indexed evaluator,
        uint256 amount
    );
    event Refunded(
        uint256 indexed jobId,
        address indexed client,
        uint256 amount
    );
    event HookWhitelistUpdated(address indexed hook, bool status);

    error InvalidJob();
    error WrongStatus();
    error Unauthorized();
    error ZeroAddress();
    error ExpiryTooShort();
    error ZeroBudget();
    error ProviderNotSet();
    error FeesTooHigh();
    error HookNotWhitelisted();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address treasury_) public initializer {
        if (treasury_ == address(0))
            revert ZeroAddress();

        __AccessControl_init();

        platformTreasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        whitelistedHooks[address(0)] = true;
    }

    /// @notice Authorize contract upgrades, restricted to DEFAULT_ADMIN_ROLE
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ──────────────────── Admin ────────────────────

    function setPlatformFee(
        uint256 feeBP_,
        address treasury_
    ) external onlyRole(ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBP_ + evaluatorFeeBP > 10000) revert FeesTooHigh();
        platformFeeBP = feeBP_;
        platformTreasury = treasury_;
    }

    function setEvaluatorFee(uint256 feeBP_) external onlyRole(ADMIN_ROLE) {
        if (feeBP_ + platformFeeBP > 10000) revert FeesTooHigh();
        evaluatorFeeBP = feeBP_;
    }

    /// @notice Whitelist or remove a hook contract
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

    // ──────────────────── Hook Helpers ────────────────────

    function _beforeHook(
        address hook,
        uint256 jobId,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook != address(0)) {
            IACPHook(hook).beforeAction(jobId, selector, data);
        }
    }

    function _afterHook(
        address hook,
        uint256 jobId,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook != address(0)) {
            IACPHook(hook).afterAction(jobId, selector, data);
        }
    }

    // ──────────────────── Job Lifecycle ────────────────────

    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook,
        uint256 agentId
    ) external nonReentrant returns (uint256) {
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        if (!whitelistedHooks[hook]) revert HookNotWhitelisted();
        if (hook != address(0)) {
            if (
                !ERC165Checker.supportsInterface(
                    hook,
                    type(IACPHook).interfaceId
                )
            ) revert InvalidJob();
        }

        uint256 jobId = ++jobCounter;
        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            provider: provider,
            evaluator: evaluator,
            description: description,
            budget: 0,
            expiredAt: expiredAt,
            status: JobStatus.Open,
            hook: hook,
            paymentToken: address(0),
            providerAgentId: provider != address(0) ? agentId : 0
        });

        emit JobCreated(
            jobId,
            msg.sender,
            provider,
            evaluator,
            expiredAt,
            hook
        );

        _afterHook(
            hook,
            jobId,
            msg.sig,
            abi.encode(msg.sender, provider, evaluator)
        );

        return jobId;
    }

    function setProvider(uint256 jobId, address provider_, uint256 agentId) external {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert WrongStatus();
        if (provider_ == address(0)) revert ZeroAddress();
        job.provider = provider_;
        job.providerAgentId = agentId;
        emit ProviderSet(jobId, provider_, agentId);
    }

    function setBudget(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();
        if (token == address(0)) revert ZeroAddress();

        bytes memory data = abi.encode(msg.sender, token, amount, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.paymentToken = token;
        job.budget = amount;
        emit BudgetSet(jobId, token, amount);
        jobHasBudget[jobId] = true;

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function fund(
        uint256 jobId,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();

        bytes memory data = abi.encode(msg.sender, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.status = JobStatus.Funded;
        if (job.budget > 0) {
            IERC20(job.paymentToken).safeTransferFrom(
                job.client,
                address(this),
                job.budget
            );
        }
        emit JobFunded(jobId, job.client, job.budget);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function submit(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (
            job.status != JobStatus.Funded &&
            (job.status != JobStatus.Open || job.budget > 0) // Allow Open job with 0 budget to be submitted
        ) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();

        bytes memory data = abi.encode(msg.sender, deliverable, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.status = JobStatus.Submitted;
        emit JobSubmitted(jobId, job.provider, deliverable);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function complete(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Submitted) revert WrongStatus();
        if (msg.sender != job.evaluator) revert Unauthorized();

        bytes memory data = abi.encode(msg.sender, reason, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.status = JobStatus.Completed;

        uint256 amount = job.budget;
        uint256 platformFee = (amount * platformFeeBP) / 10000;
        uint256 evalFee = (amount * evaluatorFeeBP) / 10000;
        uint256 net = amount - platformFee - evalFee;

        IERC20 token = IERC20(job.paymentToken);
        if (platformFee > 0) {
            token.safeTransfer(platformTreasury, platformFee);
        }
        if (evalFee > 0) {
            token.safeTransfer(job.evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, evalFee);
        }
        if (net > 0) {
            token.safeTransfer(job.provider, net);
        }

        emit JobCompleted(jobId, job.evaluator, reason);
        emit PaymentReleased(jobId, job.provider, net);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function reject(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();

        if (job.status == JobStatus.Open) {
            if (msg.sender != job.client) revert Unauthorized();
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

        if (
            (prev == JobStatus.Funded || prev == JobStatus.Submitted) &&
            job.budget > 0
        ) {
            IERC20(job.paymentToken).safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }

        emit JobRejected(jobId, msg.sender, reason);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Funded && job.status != JobStatus.Submitted)
            revert WrongStatus();
        if (block.timestamp < job.expiredAt) revert WrongStatus();

        job.status = JobStatus.Expired;

        if (job.budget > 0) {
            IERC20(job.paymentToken).safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }

        emit JobExpired(jobId);
    }

    // ──────────────────── View ────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }
}

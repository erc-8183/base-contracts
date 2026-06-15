// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC8183} from "../contracts/ERC8183.sol";
import {IERC8183Hook} from "../contracts/IERC8183Hook.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {MockCBBTC} from "../contracts/mocks/MockCBBTC.sol";
import {
    IReentrantERC8183,
    MockDisburser,
    NotADisburser,
    ReentrantDisburser
} from "../contracts/mocks/MockDisburser.sol";
import {MockFeeOnTransferToken} from "../contracts/mocks/MockFeeOnTransferToken.sol";

contract PendingClaimObserverHook is IERC8183Hook {
    ERC8183 immutable core;

    bytes32 public beforeSubmitPendingClaimHash;
    bytes32 public afterSubmitPendingClaimHash;

    constructor(ERC8183 core_) {
        core = core_;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata) external override {
        if (selector == ERC8183.submit.selector) {
            beforeSubmitPendingClaimHash = core.pendingClaimHash(jobId);
        }
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override {
        if (selector == ERC8183.submit.selector) {
            afterSubmitPendingClaimHash = core.pendingClaimHash(jobId);
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Records before/after hook invocations for assertions.
contract RecordingHook is IERC8183Hook {
    bytes4 public lastSelector;
    uint256 public beforeCount;
    uint256 public afterCount;
    bytes public lastData;

    function beforeAction(uint256, bytes4 selector, bytes calldata data) external override {
        lastSelector = selector;
        beforeCount++;
        lastData = data;
    }

    function afterAction(uint256, bytes4 selector, bytes calldata data) external override {
        lastSelector = selector;
        afterCount++;
        lastData = data;
    }

    function supportsInterface(bytes4 id) external pure override returns (bool) {
        return id == type(IERC8183Hook).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice Reverts on every callback — used to prove hooks can gate transitions.
contract RevertingHook is IERC8183Hook {
    function beforeAction(uint256, bytes4, bytes calldata) external pure override {
        revert("blocked");
    }

    function afterAction(uint256, bytes4, bytes calldata) external pure override {
        revert("blocked");
    }

    function supportsInterface(bytes4 id) external pure override returns (bool) {
        return id == type(IERC8183Hook).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice Image Generation — E2E flow (no hook, core-only payment).
///         Mirrors the original Hardhat suite in test/ERC8183.test.js.
contract ERC8183Test is Test {
    uint256 constant TWENTY_USDC = 20_000_000; // 6 decimals
    uint256 constant TEN_USDC = 10_000_000;
    uint256 constant ONE_CBBTC = 100_000_000; // 8 decimals
    bytes32 constant EMPTY_DELIVERABLE = bytes32(0);

    ERC8183 core;
    MockUSDC usdc;

    address deployer = makeAddr("deployer");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address evaluator = makeAddr("evaluator");

    // Events (must match ERC8183.sol exactly for vm.expectEmit)
    event ProviderSet(uint256 indexed jobId, address indexed actor, address indexed provider, uint256 agentId);
    event BudgetSet(uint256 indexed jobId, address indexed token, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event PaymentReleased(uint256 indexed jobId, address indexed recipient, uint256 amount);
    event PayoutReceiverSet(uint256 indexed jobId, address indexed payoutReceiver);
    event Disbursed(uint256 indexed jobId, address indexed receiver, bytes4 selector, uint256 amount);
    event PaymentTokenAllowlistUpdated(address indexed token, bool status);
    event Settled(uint256 indexed jobId, uint256 cumulativeAmount, uint256 delta);
    event ClaimSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverable,
        bytes optParams
    );
    event ClaimSettled(
        uint256 indexed jobId, address indexed settler, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable
    );
    event ClaimApproved(
        uint256 indexed jobId, address indexed approver, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable
    );
    event ClaimRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);

    function setUp() public {
        vm.startPrank(deployer);

        usdc = new MockUSDC();

        ERC8183 impl = new ERC8183();
        bytes memory initData = abi.encodeCall(ERC8183.initialize, (deployer, deployer));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        core = ERC8183(address(proxy));

        core.setPaymentTokenAllowed(address(usdc), true);

        vm.stopPrank();

        // Mint USDC to client and approve core
        usdc.mint(client, TWENTY_USDC);
        vm.prank(client);
        usdc.approve(address(core), TWENTY_USDC);
    }

    function _futureExpiry() internal view returns (uint48) {
        return uint48(block.timestamp + 3600);
    }

    function _createFundedJob(uint256 amount) internal returns (uint256 jobId) {
        return _createFundedJob(amount, address(0));
    }

    function _createFundedJob(uint256 amount, address payoutReceiver) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(provider, evaluator, _futureExpiry(), "claim job", address(0), 0);
        if (payoutReceiver != address(0)) {
            vm.prank(provider);
            core.setPayoutReceiver(jobId, payoutReceiver);
        }
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), amount, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), amount, "");
    }

    function _createSubmittedJob(address payoutReceiver) internal returns (uint256 jobId) {
        jobId = _createFundedJob(TWENTY_USDC, payoutReceiver);
        vm.prank(provider);
        core.submit(jobId, bytes32("done"), "");
    }

    function _claimBindingHash(uint256 amount, bytes32 deliverable, bytes memory optParams)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(amount, deliverable, keccak256(optParams)));
    }

    function _hasPaymentReleasedLog(Vm.Log[] memory entries) internal pure returns (bool) {
        bytes32 topic = keccak256("PaymentReleased(uint256,address,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _assertReentryBlocked(ReentrantDisburser disburser) internal view {
        assertTrue(disburser.attempted());
        assertFalse(disburser.reentered());
        assertTrue(disburser.reentryReverted());

        bytes memory revertData = disburser.revertData();
        assertEq(revertData.length, 4);

        bytes4 actualSelector;
        assembly {
            actualSelector := mload(add(revertData, 32))
        }
        assertEq(actualSelector, bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    }

    // ──────────────────────────────────────────────────────────
    // e2e: two jobs on the same contract using different tokens
    // ──────────────────────────────────────────────────────────
    function test_e2e_TwoJobsDifferentTokens() public {
        MockCBBTC cbbtc = new MockCBBTC();

        vm.prank(deployer);
        core.setPaymentTokenAllowed(address(cbbtc), true);

        cbbtc.mint(client, ONE_CBBTC);
        vm.prank(client);
        cbbtc.approve(address(core), ONE_CBBTC);

        uint48 expiry = _futureExpiry();

        // Job 1: paid in USDC
        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "Job paid in USDC", address(0), 0);
        uint256 jobId1 = 1;
        vm.prank(provider);
        core.setBudget(jobId1, address(usdc), TWENTY_USDC, "");
        assertEq(core.getJob(jobId1).paymentToken, address(usdc));

        // Job 2: paid in cbBTC
        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "Job paid in cbBTC", address(0), 0);
        uint256 jobId2 = 2;
        vm.prank(provider);
        core.setBudget(jobId2, address(cbbtc), ONE_CBBTC, "");
        assertEq(core.getJob(jobId2).paymentToken, address(cbbtc));

        // Fund both
        vm.prank(client);
        core.fund(jobId1, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId2, address(cbbtc), ONE_CBBTC, "");

        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);
        assertEq(cbbtc.balanceOf(address(core)), ONE_CBBTC);

        // Submit + complete both
        bytes32 deliverable = bytes32("done");
        bytes32 reason = bytes32("approved");

        vm.prank(provider);
        core.submit(jobId1, deliverable, "");
        vm.prank(provider);
        core.submit(jobId2, deliverable, "");
        vm.prank(evaluator);
        core.complete(jobId1, reason, "");
        vm.prank(evaluator);
        core.complete(jobId2, reason, "");

        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
        assertEq(cbbtc.balanceOf(provider), ONE_CBBTC);
    }

    // ──────────────────────────────────────────────────────────
    // agentId stored + emitted via createJob and setProvider
    // ──────────────────────────────────────────────────────────
    function test_agentId_StoredAndEmitted() public {
        uint48 expiry = _futureExpiry();
        uint256 AGENT_ID = 42;

        // createJob with agentId when provider is known
        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "Job with agentId", address(0), AGENT_ID);
        assertEq(core.getJob(1).providerAgentId, AGENT_ID);

        // createJob without provider: agentId should be 0 even if a non-zero value is passed
        vm.prank(client);
        core.createJob(address(0), evaluator, expiry, "Job without provider", address(0), 99);
        assertEq(core.getJob(2).providerAgentId, 0);

        uint256 AGENT_ID_2 = 7;
        vm.expectEmit(true, true, true, true, address(core));
        emit ProviderSet(2, client, provider, AGENT_ID_2);
        vm.prank(client);
        core.setProvider(2, provider, AGENT_ID_2, "");

        assertEq(core.getJob(2).providerAgentId, AGENT_ID_2);

        // agentId = 0 is valid
        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "No agentId", address(0), 0);
        assertEq(core.getJob(3).providerAgentId, 0);
    }

    // ──────────────────────────────────────────────────────────
    // setProvider cannot assign the client as provider
    // ──────────────────────────────────────────────────────────
    function test_setProvider_RevertsWhenProviderIsClient() public {
        vm.prank(client);
        core.createJob(address(0), evaluator, _futureExpiry(), "Job without provider", address(0), 0);

        vm.prank(client);
        vm.expectRevert(ERC8183.ClientCannotBeProvider.selector);
        core.setProvider(1, client, 0, "");
    }

    // setProvider fires before + after hooks with the encoded payload
    function test_setProvider_firesBeforeAndAfterHooks() public {
        RecordingHook hook = new RecordingHook();
        vm.prank(deployer);
        core.setHookWhitelist(address(hook), true);

        vm.prank(client);
        core.createJob(address(0), evaluator, _futureExpiry(), "hooked", address(hook), 0);

        vm.prank(client);
        core.setProvider(1, provider, 7, hex"beef");

        assertEq(hook.lastSelector(), core.setProvider.selector);
        assertEq(hook.beforeCount(), 1);
        assertEq(hook.afterCount(), 1);
        assertEq(hook.lastData(), abi.encode(client, provider, uint256(7), bytes(hex"beef")));
    }

    // a reverting before hook gates the transition
    function test_setProvider_beforeHookRevertGates() public {
        RevertingHook hook = new RevertingHook();
        vm.prank(deployer);
        core.setHookWhitelist(address(hook), true);

        vm.prank(client);
        core.createJob(address(0), evaluator, _futureExpiry(), "hooked", address(hook), 0);

        vm.prank(client);
        vm.expectRevert(bytes("blocked"));
        core.setProvider(1, provider, 0, "");

        assertEq(core.getJob(1).provider, address(0));
    }

    // ──────────────────────────────────────────────────────────
    // e2e: client requests image, provider delivers, evaluator approves
    // ──────────────────────────────────────────────────────────
    function test_e2e_FullHappyPath() public {
        uint48 expiry = _futureExpiry();

        // Step 1: create job
        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "Generate a beautiful landscape wallpaper image", address(0), 0);
        uint256 jobId = 1;

        ERC8183.Job memory job = core.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.provider, provider);
        assertEq(job.evaluator, evaluator);
        assertEq(uint8(job.status), uint8(ERC8183.JobStatus.Open));

        // Step 2: provider sets budget — expect BudgetSet event
        vm.expectEmit(true, true, true, true, address(core));
        emit BudgetSet(jobId, address(usdc), TWENTY_USDC);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");

        assertEq(core.getJob(jobId).budget, TWENTY_USDC);

        // Step 3: client funds — expect JobFunded event
        assertEq(usdc.balanceOf(client), TWENTY_USDC);

        vm.expectEmit(true, true, true, true, address(core));
        emit JobFunded(jobId, client, TWENTY_USDC);
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        assertEq(usdc.balanceOf(client), 0);
        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Funded));

        // Step 4: provider submits
        bytes32 deliverableHash = keccak256(
            bytes(
                "https://png.pngtree.com/background/20250111/original/pngtree-nice-background-beautiful-h5-wallpaper-imag-picture-image_15708053.jpg"
            )
        );

        vm.expectEmit(true, true, true, true, address(core));
        emit JobSubmitted(jobId, provider, deliverableHash);
        vm.prank(provider);
        core.submit(jobId, deliverableHash, "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Submitted));

        // Step 5: evaluator completes — expect JobCompleted + PaymentReleased
        bytes32 completionReason = bytes32("approved");

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, TWENTY_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit JobCompleted(jobId, evaluator, completionReason);

        vm.prank(evaluator);
        core.complete(jobId, completionReason, "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    // ──────────────────────────────────────────────────────────
    // claimRefund reverts during grace period (Submitted)
    // ──────────────────────────────────────────────────────────
    function test_claimRefund_RevertsDuringGracePeriod() public {
        uint48 expiry = _futureExpiry();

        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "grace period test", address(0), 0);
        uint256 jobId = 1;

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        // Provider submits right before expiry
        vm.warp(uint256(expiry) - 60);
        vm.prank(provider);
        core.submit(jobId, bytes32("work"), "");

        // Move past expiry but within grace period
        vm.warp(uint256(expiry) + 1);
        vm.expectRevert(ERC8183.GracePeriodActive.selector);
        core.claimRefund(jobId);

        // Evaluator can still complete during grace period
        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
    }

    // ──────────────────────────────────────────────────────────
    // claimRefund succeeds after grace period expires (Submitted)
    // ──────────────────────────────────────────────────────────
    function test_claimRefund_AfterGracePeriod() public {
        uint48 expiry = _futureExpiry();

        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "grace expiry test", address(0), 0);
        uint256 jobId = 1;

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(provider);
        core.submit(jobId, bytes32("work"), "");

        // Move past expiry + grace period (1 hour)
        vm.warp(uint256(expiry) + 3601);
        core.claimRefund(jobId);
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), TWENTY_USDC);
    }

    // ──────────────────────────────────────────────────────────
    // setBudget reverts with PaymentTokenNotAllowed
    // ──────────────────────────────────────────────────────────
    function test_setBudget_RevertsWhenTokenNotAllowed() public {
        MockCBBTC notAllowed = new MockCBBTC();

        uint48 expiry = _futureExpiry();
        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "test", address(0), 0);
        uint256 jobId = 1;

        vm.expectRevert(ERC8183.PaymentTokenNotAllowed.selector);
        vm.prank(provider);
        core.setBudget(jobId, address(notAllowed), 1, "");
    }

    // ──────────────────────────────────────────────────────────
    // setPaymentTokenAllowed: only admin, emits event, ZeroAddress reverts
    // ──────────────────────────────────────────────────────────
    function test_setPaymentTokenAllowed_Authorization() public {
        MockCBBTC tok = new MockCBBTC();

        // Non-admin reverts with AccessControl error
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, client, core.ADMIN_ROLE())
        );
        vm.prank(client);
        core.setPaymentTokenAllowed(address(tok), true);

        // ZeroAddress reverts
        vm.expectRevert(ERC8183.ZeroAddress.selector);
        vm.prank(deployer);
        core.setPaymentTokenAllowed(address(0), true);

        // Admin can allow and revoke, both emit event
        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentTokenAllowlistUpdated(address(tok), true);
        vm.prank(deployer);
        core.setPaymentTokenAllowed(address(tok), true);
        assertTrue(core.allowedPaymentTokens(address(tok)));

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentTokenAllowlistUpdated(address(tok), false);
        vm.prank(deployer);
        core.setPaymentTokenAllowed(address(tok), false);
        assertFalse(core.allowedPaymentTokens(address(tok)));
    }

    // ──────────────────────────────────────────────────────────
    // fund reverts with UnexpectedFundedAmount for fee-on-transfer
    // ──────────────────────────────────────────────────────────
    function test_fund_RevertsForFeeOnTransferTokens() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        uint256 AMOUNT = 1_000_000;

        fot.mint(client, AMOUNT);
        vm.prank(client);
        fot.approve(address(core), AMOUNT);

        vm.prank(deployer);
        core.setPaymentTokenAllowed(address(fot), true);

        uint48 expiry = _futureExpiry();
        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "fot", address(0), 0);
        uint256 jobId = 1;

        vm.prank(provider);
        core.setBudget(jobId, address(fot), AMOUNT, "");

        vm.expectRevert(ERC8183.UnexpectedFundedAmount.selector);
        vm.prank(client);
        core.fund(jobId, address(fot), AMOUNT, "");

        // Escrow stayed empty
        assertEq(fot.balanceOf(address(core)), 0);
    }

    function test_fund_RevertsWhenExpectedTokenMismatchesCurrentBudgetToken() public {
        MockCBBTC cbbtc = new MockCBBTC();

        vm.prank(deployer);
        core.setPaymentTokenAllowed(address(cbbtc), true);

        cbbtc.mint(client, TWENTY_USDC);
        vm.prank(client);
        cbbtc.approve(address(core), TWENTY_USDC);

        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, _futureExpiry(), "token swap", address(0), 0);

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(provider);
        core.setBudget(jobId, address(cbbtc), TWENTY_USDC, "");

        vm.expectRevert(ERC8183.PaymentTokenMismatch.selector);
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        assertEq(usdc.balanceOf(address(core)), 0);
        assertEq(cbbtc.balanceOf(address(core)), 0);
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Open));
    }

    // ──────────────────────────────────────────────────────────
    // claimRefund: no grace period for Funded (not Submitted) jobs
    // ──────────────────────────────────────────────────────────
    function test_claimRefund_NoGraceForFundedJobs() public {
        uint48 expiry = _futureExpiry();

        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "no grace test", address(0), 0);
        uint256 jobId = 1;

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");
        // NOT submitted - stays Funded

        vm.warp(uint256(expiry) + 1);
        core.claimRefund(jobId);
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), TWENTY_USDC);
    }

    function test_claims_ClientSettleClaimFastPathReleasesDelta() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(provider);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSettled(jobId, client, TEN_USDC, TEN_USDC, EMPTY_DELIVERABLE);
        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
        assertEq(usdc.balanceOf(address(core)), TEN_USDC);
    }

    function test_claims_SettleClaimRevertsWhenCumulativeAmountExceedsBudget() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);

        vm.expectRevert(ERC8183.ExceedsBudget.selector);
        vm.prank(client);
        core.settleClaim(jobId, TWENTY_USDC + 1, EMPTY_DELIVERABLE, "");

        assertEq(core.getJob(jobId).settledAmount, 0);
        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);
    }

    function test_claims_SettleClaimAppliesConfiguredFeesToDelta() public {
        vm.prank(deployer);
        core.setPlatformFee(1_000, deployer);
        vm.prank(deployer);
        core.setEvaluatorFee(500);

        uint256 jobId = _createFundedJob(TWENTY_USDC);

        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(usdc.balanceOf(deployer), 1_000_000);
        assertEq(usdc.balanceOf(evaluator), 500_000);
        assertEq(usdc.balanceOf(provider), 8_500_000);
        assertEq(usdc.balanceOf(address(core)), TEN_USDC);
    }

    function test_claims_SettleClaimSkipsPaymentAndCallbackWhenNetZero() public {
        MockDisburser disburser = new MockDisburser();
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(disburser));

        vm.prank(deployer);
        core.setEvaluatorFee(10_000);

        vm.recordLogs();
        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertFalse(_hasPaymentReleasedLog(entries));
        assertEq(usdc.balanceOf(evaluator), TEN_USDC);
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(address(disburser)), 0);
        assertEq(disburser.callCount(), 0);
    }

    function test_claims_NonzeroDeliverableRecordsPendingHashAndSettlesOnApproval() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);
        bytes32 deliverable = bytes32("milestone-1");
        bytes memory optParams = hex"1234";

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(client);
        core.submitClaim(jobId, TEN_USDC, deliverable, optParams);

        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSubmitted(jobId, provider, TEN_USDC, TEN_USDC, deliverable, optParams);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, optParams);

        assertEq(core.getJob(jobId).settledAmount, 0);
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, deliverable, optParams));
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimApproved(jobId, evaluator, TEN_USDC, TEN_USDC, deliverable);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, deliverable, optParams);

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
        assertEq(usdc.balanceOf(address(core)), TEN_USDC);
    }

    function test_payoutReceiver_ZeroAddressKeepsPayProviderDirectlyBehavior() public {
        uint256 jobId = _createSubmittedJob(address(0));

        assertEq(core.getJob(jobId).payoutReceiver, address(0));

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, TWENTY_USDC);
        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
    }

    function test_payoutReceiver_DisburserContractReceivesFundsAndCallback() public {
        MockDisburser disburser = new MockDisburser();
        uint256 jobId = _createSubmittedJob(address(disburser));

        bytes4 completeSelector = core.complete.selector;
        bytes memory callbackData = hex"deadbeef";

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, address(disburser), TWENTY_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Disbursed(jobId, address(disburser), completeSelector, TWENTY_USDC);
        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), callbackData);

        assertEq(usdc.balanceOf(address(disburser)), TWENTY_USDC);
        assertEq(disburser.callCount(), 1);
        assertEq(disburser.lastJobId(), jobId);
        assertEq(disburser.lastSelector(), completeSelector);
        assertEq(disburser.lastToken(), address(usdc));
        assertEq(disburser.lastAmount(), TWENTY_USDC);
        assertEq(disburser.lastData(), callbackData);
    }

    function test_payoutReceiver_CompletionPaysFeesAndReceiverGetsOnlyNet() public {
        MockDisburser disburser = new MockDisburser();
        uint256 jobId = _createSubmittedJob(address(disburser));

        vm.startPrank(deployer);
        core.setPlatformFee(1_000, deployer);
        core.setEvaluatorFee(1_000);
        vm.stopPrank();

        uint256 fee = 2_000_000;
        uint256 net = 16_000_000;

        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        assertEq(usdc.balanceOf(deployer), fee);
        assertEq(usdc.balanceOf(evaluator), fee);
        assertEq(usdc.balanceOf(address(disburser)), net);
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(disburser.lastAmount(), net);
    }

    function test_payoutReceiver_EOAReceiverReceivesFundsWithoutCallback() public {
        address payoutReceiver = makeAddr("payoutReceiver");
        uint256 jobId = _createSubmittedJob(payoutReceiver);

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, payoutReceiver, TWENTY_USDC);
        vm.recordLogs();
        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 disbursedTopic = keccak256("Disbursed(uint256,address,bytes4,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == disbursedTopic);
        }
        assertEq(usdc.balanceOf(payoutReceiver), TWENTY_USDC);
    }

    function test_payoutReceiver_NonDisburserContractReceivesFundsWithoutCallback() public {
        NotADisburser receiver = new NotADisburser();
        uint256 jobId = _createSubmittedJob(address(receiver));

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, address(receiver), TWENTY_USDC);
        vm.recordLogs();
        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 disbursedTopic = keccak256("Disbursed(uint256,address,bytes4,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == disbursedTopic);
        }
        assertEq(usdc.balanceOf(address(receiver)), TWENTY_USDC);
    }

    function test_payoutReceiver_RevertsWhenReceiverIsEscrow() public {
        vm.prank(client);
        core.createJob(provider, evaluator, _futureExpiry(), "setter self receiver", address(0), 0);

        vm.expectRevert(ERC8183.InvalidReceiver.selector);
        vm.prank(provider);
        core.setPayoutReceiver(1, address(core));
    }

    function test_payoutReceiver_RevertsWhenReceiverIsPaymentTokenAfterBudget() public {
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, _futureExpiry(), "receiver token", address(0), 0);

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");

        vm.expectRevert(ERC8183.InvalidReceiver.selector);
        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(usdc));
    }

    function test_setBudget_RevertsWhenExistingReceiverIsPaymentToken() public {
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, _futureExpiry(), "budget token receiver", address(0), 0);

        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(usdc));

        vm.expectRevert(ERC8183.InvalidReceiver.selector);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
    }

    function test_payoutReceiver_RefundsClientWhenReceiverIsSet() public {
        address payoutReceiver = makeAddr("payoutReceiver");
        uint48 expiry = _futureExpiry();

        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, expiry, "refund receiver", address(0), 0);

        vm.prank(provider);
        core.setPayoutReceiver(jobId, payoutReceiver);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        vm.warp(uint256(expiry) + 1);
        core.claimRefund(jobId);

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), TWENTY_USDC);
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(payoutReceiver), 0);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_setPayoutReceiver_ProviderOnlyOpenOnlyAcceptsPlainContractsAndLocksAfterFund() public {
        MockDisburser disburser = new MockDisburser();
        NotADisburser plainReceiver = new NotADisburser();
        uint48 expiry = _futureExpiry();

        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "setter test", address(0), 0);
        uint256 jobId = 1;

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(client);
        core.setPayoutReceiver(jobId, address(disburser));

        vm.expectEmit(true, true, true, true, address(core));
        emit PayoutReceiverSet(jobId, address(plainReceiver));
        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(plainReceiver));

        vm.expectEmit(true, true, true, true, address(core));
        emit PayoutReceiverSet(jobId, address(disburser));
        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(disburser));
        assertEq(core.getJob(jobId).payoutReceiver, address(disburser));

        vm.expectEmit(true, true, true, true, address(core));
        emit PayoutReceiverSet(jobId, address(0));
        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(0));
        assertEq(core.getJob(jobId).payoutReceiver, address(0));

        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(disburser));

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(0));
    }

    function test_setPayoutReceiver_RevertsForInvalidJob() public {
        vm.expectRevert(ERC8183.InvalidJob.selector);
        vm.prank(provider);
        core.setPayoutReceiver(1, address(0));
    }

    function test_setPayoutReceiver_AssignedProviderCanSetReceiver() public {
        address payoutReceiver = makeAddr("assignedProviderReceiver");

        vm.prank(client);
        core.createJob(address(0), evaluator, _futureExpiry(), "late receiver provider", address(0), 0);

        vm.prank(client);
        core.setProvider(1, provider, 0, "");

        vm.expectEmit(true, true, true, true, address(core));
        emit PayoutReceiverSet(1, payoutReceiver);
        vm.prank(provider);
        core.setPayoutReceiver(1, payoutReceiver);

        assertEq(core.getJob(1).payoutReceiver, payoutReceiver);
    }

    function test_setPayoutReceiver_RevertsAfterExpiry() public {
        uint48 expiry = _futureExpiry();

        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "expired receiver", address(0), 0);

        vm.warp(uint256(expiry));
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(provider);
        core.setPayoutReceiver(1, makeAddr("lateReceiver"));
    }

    function test_complete_RevertsWhenReceiverDisburserRevertsStrictly() public {
        MockDisburser disburser = new MockDisburser();
        uint256 jobId = _createSubmittedJob(address(disburser));

        disburser.setShouldRevert(true);

        vm.expectRevert(bytes("MockDisburser: forced revert"));
        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Submitted));
        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);
    }

    function test_payoutReceiver_ReentrantDisburserCannotReenterSettleClaim() public {
        ReentrantDisburser disburser = new ReentrantDisburser();
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(disburser));
        disburser.setReentry(
            IReentrantERC8183(address(core)), jobId, TWENTY_USDC, ReentrantDisburser.Action.SettleClaim
        );

        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(usdc.balanceOf(address(disburser)), TEN_USDC);
        _assertReentryBlocked(disburser);
    }

    function test_payoutReceiver_ReentrantDisburserCannotReenterComplete() public {
        ReentrantDisburser disburser = new ReentrantDisburser();
        uint256 jobId = _createSubmittedJob(address(disburser));
        disburser.setReentry(IReentrantERC8183(address(core)), jobId, 0, ReentrantDisburser.Action.Complete);

        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(address(disburser)), TWENTY_USDC);
        _assertReentryBlocked(disburser);
    }

    function test_payoutReceiver_ReentrantDisburserCannotReenterClaimRefund() public {
        ReentrantDisburser disburser = new ReentrantDisburser();
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(disburser));
        disburser.setReentry(IReentrantERC8183(address(core)), jobId, 0, ReentrantDisburser.Action.ClaimRefund);

        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(usdc.balanceOf(address(disburser)), TEN_USDC);
        _assertReentryBlocked(disburser);
    }

    function test_claims_SettleClaimPaysReceiverAndFiresDisbursement() public {
        MockDisburser disburser = new MockDisburser();
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(disburser));
        bytes memory callbackData = hex"cafe";

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, address(disburser), TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Disbursed(jobId, address(disburser), core.settleClaim.selector, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSettled(jobId, client, TEN_USDC, TEN_USDC, EMPTY_DELIVERABLE);
        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, callbackData);

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(usdc.balanceOf(address(disburser)), TEN_USDC);
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(disburser.callCount(), 1);
        assertEq(disburser.lastSelector(), core.settleClaim.selector);
        assertEq(disburser.lastData(), callbackData);
    }

    function test_claims_SettleClaimRevertsWhenReceiverDisburserRevertsStrictly() public {
        MockDisburser disburser = new MockDisburser();
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(disburser));

        disburser.setShouldRevert(true);

        vm.expectRevert(bytes("MockDisburser: forced revert"));
        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");

        assertEq(core.getJob(jobId).settledAmount, 0);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(disburser)), 0);
        assertEq(usdc.balanceOf(provider), 0);
    }

    function test_claims_ApprovedNonzeroDeliverableSettlementPaysReceiverAndFiresDisbursement() public {
        MockDisburser disburser = new MockDisburser();
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(disburser));
        bytes32 deliverable = bytes32("milestone-1");
        bytes memory optParams = hex"1234";

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, optParams);

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, address(disburser), TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Disbursed(jobId, address(disburser), core.approveClaim.selector, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimApproved(jobId, evaluator, TEN_USDC, TEN_USDC, deliverable);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, deliverable, optParams);

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(address(disburser)), TEN_USDC);
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(disburser.callCount(), 1);
        assertEq(disburser.lastSelector(), core.approveClaim.selector);
        assertEq(disburser.lastData(), optParams);
    }

    function test_claims_ApproveClaimRevertsWhenReceiverDisburserRevertsStrictly() public {
        MockDisburser disburser = new MockDisburser();
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(disburser));
        bytes32 deliverable = bytes32("milestone-1");
        bytes memory optParams = hex"1234";

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, optParams);

        bytes32 claimHash = _claimBindingHash(TEN_USDC, deliverable, optParams);
        assertEq(core.pendingClaimHash(jobId), claimHash);

        disburser.setShouldRevert(true);

        vm.expectRevert(bytes("MockDisburser: forced revert"));
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, deliverable, optParams);

        assertEq(core.getJob(jobId).settledAmount, 0);
        assertEq(core.pendingClaimHash(jobId), claimHash);
        assertEq(usdc.balanceOf(address(core)), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(disburser)), 0);
        assertEq(usdc.balanceOf(provider), 0);
    }

    function test_claims_SubmitClaimRejectsZeroDeliverableAndPendingOverwrite() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);
        bytes32 deliverable = bytes32("milestone-1");

        vm.expectRevert(ERC8183.EmptyDeliverable.selector);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");

        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        vm.prank(provider);
        core.submitClaim(jobId, TWENTY_USDC, bytes32("milestone-2"), "");
    }

    function test_claims_SubmitClaimRevertsAtExpiry() public {
        uint48 expiry = _futureExpiry();
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, expiry, "expired claim", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        vm.warp(expiry);

        bytes32 deliverable = "milestone-1";
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");
    }

    function test_claims_SettleClaimRevertsAtExpiry() public {
        uint48 expiry = _futureExpiry();
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, expiry, "expired settlement", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        vm.warp(expiry);

        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");
    }

    function test_claims_SettleClaimContinuesWhilePendingClaimExists() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);
        bytes32 deliverable = bytes32("milestone-1");

        vm.prank(provider);
        core.submitClaim(jobId, TWENTY_USDC, deliverable, "");
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TWENTY_USDC, deliverable, ""));

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSettled(jobId, client, TEN_USDC, TEN_USDC, deliverable);
        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, deliverable, "");

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TWENTY_USDC, deliverable, ""));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
        assertEq(usdc.balanceOf(address(core)), TEN_USDC);

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TWENTY_USDC, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimApproved(jobId, evaluator, TWENTY_USDC, TEN_USDC, deliverable);
        vm.prank(evaluator);
        core.approveClaim(jobId, TWENTY_USDC, deliverable, "");

        assertEq(core.getJob(jobId).settledAmount, TWENTY_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_claims_DeadPendingClaimCanBeRejectedThenRefunded() public {
        uint48 expiry = _futureExpiry();
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, expiry, "dead claim", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        bytes32 deliverable = "milestone-1";
        bytes32 streamDeliverable = "stream";
        bytes32 staleReason = "stale";
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");

        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, streamDeliverable, "");

        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, deliverable, "");

        vm.warp(uint256(expiry) + 1);
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        core.claimRefund(jobId);

        vm.prank(client);
        core.rejectClaim(jobId, TEN_USDC, deliverable, staleReason, "");

        core.claimRefund(jobId);

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Expired));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
        assertEq(usdc.balanceOf(client), TEN_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_claims_SubmitClearsPendingClaimAndCompletesFullEscrow() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);
        bytes32 claimDeliverable = bytes32("milestone-1");
        bytes32 supersededReason = bytes32("superseded-by-submit");

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, claimDeliverable, "");
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, claimDeliverable, ""));

        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimRejected(jobId, provider, supersededReason);
        vm.prank(provider);
        core.submit(jobId, bytes32("final"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Submitted));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));

        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
        assertEq(core.getJob(jobId).settledAmount, 0);
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_claims_CompletePaysOnlyUnsettledRemainderAfterPartialSettlement() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);

        vm.prank(client);
        core.settleClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, "");

        vm.prank(provider);
        core.submit(jobId, bytes32("final"), "");

        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_claims_SubmitClearsPendingClaimBeforeHook() public {
        PendingClaimObserverHook hook = new PendingClaimObserverHook(core);
        vm.prank(deployer);
        core.setHookWhitelist(address(hook), true);

        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, _futureExpiry(), "hooked claim job", address(hook), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        bytes32 claimDeliverable = bytes32("milestone-1");
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, claimDeliverable, "");
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, claimDeliverable, ""));

        vm.prank(provider);
        core.submit(jobId, bytes32("final"), "");

        assertEq(hook.beforeSubmitPendingClaimHash(), bytes32(0));
        assertEq(hook.afterSubmitPendingClaimHash(), bytes32(0));
    }

    function test_claims_RejectFundedJobClearsPendingClaim() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);
        bytes32 deliverable = bytes32("milestone-1");
        bytes32 reason = bytes32("job-rejected");

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, deliverable, ""));

        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimRejected(jobId, evaluator, reason);
        vm.prank(evaluator);
        core.reject(jobId, reason, "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Rejected));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(client), TWENTY_USDC);
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_claims_ApproveClaimRevertsWhenNoPendingClaimAfterReject() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);
        bytes32 deliverable = bytes32("milestone-1");
        bytes32 reason = bytes32("rejected");

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");

        vm.prank(client);
        core.rejectClaim(jobId, TEN_USDC, deliverable, reason, "");

        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, deliverable, "");
    }

    function test_claims_ApproveClaimRevertsWhenClaimBindingDiffers() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);
        bytes32 deliverable = bytes32("milestone-1");
        bytes memory optParams = hex"1234";

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, optParams);

        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, deliverable, hex"5678");

        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, deliverable, optParams));
        assertEq(core.getJob(jobId).settledAmount, 0);
    }

    function test_claims_ProviderCanRejectOwnPendingClaimAndSubmitNewClaim() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC);
        bytes32 deliverable = bytes32("milestone-1");
        bytes32 reason = bytes32("withdrawn");

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");

        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimRejected(jobId, provider, reason);
        vm.prank(provider);
        core.rejectClaim(jobId, TEN_USDC, deliverable, reason, "");

        assertEq(core.pendingClaimHash(jobId), bytes32(0));

        vm.expectRevert(ERC8183.ClaimAlreadySubmitted.selector);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, bytes32("milestone-2"), "");

        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, bytes32("milestone-2"), ""));
    }

    function test_claims_PendingClaimBlocksRefundUntilResolved() public {
        uint48 expiry = _futureExpiry();
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, expiry, "pending claim block", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        bytes32 deliverable = bytes32("milestone-1");
        vm.warp(uint256(expiry) - 1);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");

        vm.warp(uint256(expiry) + 30 days);
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        core.claimRefund(jobId);

        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, deliverable, "");

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
        assertEq(usdc.balanceOf(address(core)), TEN_USDC);
    }

    function test_claims_RejectPendingClaimAfterExpiryThenRefundsRemainingEscrow() public {
        uint48 expiry = _futureExpiry();
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, expiry, "pending claim reject", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");

        bytes32 deliverable = bytes32("milestone-1");
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");

        vm.warp(uint256(expiry) + 30 days);
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        core.claimRefund(jobId);

        vm.prank(provider);
        core.rejectClaim(jobId, TEN_USDC, deliverable, bytes32("withdrawn"), "");

        core.claimRefund(jobId);

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Expired));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(client), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
    }
}

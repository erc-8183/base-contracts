// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ERC8183} from "../contracts/ERC8183.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {MockCBBTC} from "../contracts/mocks/MockCBBTC.sol";
import {MockFeeOnTransferToken} from "../contracts/mocks/MockFeeOnTransferToken.sol";
import {MockHook} from "../contracts/mocks/MockHook.sol";

/// @notice Image Generation — E2E flow (no hook, core-only payment).
///         Mirrors the original Hardhat suite in test/ERC8183.test.js.
contract ERC8183Test is Test {
    uint256 constant TWENTY_USDC = 20_000_000; // 6 decimals
    uint256 constant TEN_USDC = 10_000_000;
    uint256 constant FIVE_USDC = 5_000_000;
    uint256 constant ONE_USDC = 1_000_000;
    uint256 constant ONE_CBBTC = 100_000_000; // 8 decimals
    bytes32 constant EMPTY_DELIVERABLE = bytes32(0);
    bytes32 constant DELIVERABLE_A = bytes32("deliverable-a");
    bytes32 constant DELIVERABLE_B = bytes32("deliverable-b");
    bytes constant OPT_PARAMS_A = hex"1234";
    bytes constant OPT_PARAMS_B = hex"abcd";

    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant CLAIM_VOUCHER_TYPEHASH =
        keccak256("ClaimVoucher(uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes optParams)");

    ERC8183 core;
    MockUSDC usdc;

    address deployer = makeAddr("deployer");
    address client;
    uint256 clientPk;
    address provider;
    uint256 providerPk;
    address evaluator;
    uint256 evaluatorPk;
    address outsider = makeAddr("outsider");

    // Events (must match ERC8183.sol exactly for vm.expectEmit)
    event ProviderSet(uint256 indexed jobId, address indexed provider, uint256 agentId);
    event BudgetSet(uint256 indexed jobId, address indexed token, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event PlatformFeePaid(uint256 indexed jobId, address indexed platformTreasury, uint256 amount);
    event EvaluatorFeePaid(uint256 indexed jobId, address indexed evaluator, uint256 amount);
    event PaymentTokenAllowlistUpdated(address indexed token, bool status);
    event Settled(uint256 indexed jobId, uint256 cumulativeAmount, uint256 delta);
    event ClaimSubmitted(
        uint256 indexed jobId, address indexed provider, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable
    );
    event ClaimApproved(
        uint256 indexed jobId, address indexed approver, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable
    );
    event ClaimRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event BeforeAction(uint256 indexed jobId, bytes4 selector, bytes data);

    function setUp() public {
        (client, clientPk) = makeAddrAndKey("client");
        (provider, providerPk) = makeAddrAndKey("provider");
        (evaluator, evaluatorPk) = makeAddrAndKey("evaluator");

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

    function _createFundedJob(uint256 amount) internal returns (uint256 jobId, uint48 expiry) {
        expiry = _futureExpiry();

        vm.prank(client);
        jobId = core.createJob(provider, evaluator, expiry, "partial settlement job", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), amount, "");
        vm.prank(client);
        core.fund(jobId, amount, "");
    }

    function _signClaim(
        uint256 signerPk,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(CLAIM_VOUCHER_TYPEHASH, jobId, cumulativeAmount, deliverable, keccak256(optParams))
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes("ERC8183")), keccak256(bytes("1")), block.chainid, address(core)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signClaim(uint256 signerPk, uint256 jobId, uint256 cumulativeAmount, bytes32 deliverable)
        internal
        view
        returns (bytes memory)
    {
        return _signClaim(signerPk, jobId, cumulativeAmount, deliverable, "");
    }

    function _claimBindingHash(uint256 cumulativeAmount, bytes32 deliverable, bytes memory optParams)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(cumulativeAmount, deliverable, keccak256(optParams)));
    }

    function _claimBindingHash(uint256 cumulativeAmount, bytes32 deliverable) internal pure returns (bytes32) {
        return _claimBindingHash(cumulativeAmount, deliverable, "");
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
        core.fund(jobId1, TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId2, ONE_CBBTC, "");

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
        emit ProviderSet(2, provider, AGENT_ID_2);
        vm.prank(client);
        core.setProvider(2, provider, AGENT_ID_2);

        assertEq(core.getJob(2).providerAgentId, AGENT_ID_2);

        // agentId = 0 is valid
        vm.prank(client);
        core.createJob(provider, evaluator, expiry, "No agentId", address(0), 0);
        assertEq(core.getJob(3).providerAgentId, 0);
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
        core.fund(jobId, TWENTY_USDC, "");

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
        core.fund(jobId, TWENTY_USDC, "");

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
        core.fund(jobId, TWENTY_USDC, "");
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
        core.fund(jobId, AMOUNT, "");

        // Escrow stayed empty
        assertEq(fot.balanceOf(address(core)), 0);
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
        core.fund(jobId, TWENTY_USDC, "");
        // NOT submitted - stays Funded

        vm.warp(uint256(expiry) + 1);
        core.claimRefund(jobId);
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), TWENTY_USDC);
    }

    function test_submitClaim_FastPathChargesFeesOnSettlementDelta() public {
        vm.prank(deployer);
        core.setPlatformFee(1000, deployer);
        vm.prank(deployer);
        core.setEvaluatorFee(500);

        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, EMPTY_DELIVERABLE);

        vm.expectEmit(true, true, true, true, address(core));
        emit PlatformFeePaid(jobId, deployer, ONE_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit EvaluatorFeePaid(jobId, evaluator, 500_000);
        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, 8_500_000);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, TEN_USDC);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, sig, "");

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(usdc.balanceOf(deployer), ONE_USDC);
        assertEq(usdc.balanceOf(evaluator), 500_000);
        assertEq(usdc.balanceOf(provider), 8_500_000);
        assertEq(usdc.balanceOf(address(core)), TEN_USDC);
    }

    function test_submitClaim_FastPathOnlyPaysNewDeltaForIncreasingClaims() public {
        vm.prank(deployer);
        core.setPlatformFee(1000, deployer);
        vm.prank(deployer);
        core.setEvaluatorFee(500);

        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory firstSig = _signClaim(clientPk, jobId, FIVE_USDC, EMPTY_DELIVERABLE);
        bytes memory secondSig = _signClaim(clientPk, jobId, TEN_USDC, EMPTY_DELIVERABLE);

        vm.prank(provider);
        core.submitClaim(jobId, FIVE_USDC, EMPTY_DELIVERABLE, firstSig, "");

        vm.expectEmit(true, true, true, true, address(core));
        emit PlatformFeePaid(jobId, deployer, 500_000);
        vm.expectEmit(true, true, true, true, address(core));
        emit EvaluatorFeePaid(jobId, evaluator, 250_000);
        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, 4_250_000);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, FIVE_USDC);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, secondSig, "");

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(usdc.balanceOf(deployer), ONE_USDC);
        assertEq(usdc.balanceOf(evaluator), 500_000);
        assertEq(usdc.balanceOf(provider), 8_500_000);
        assertEq(usdc.balanceOf(address(core)), TEN_USDC);
    }

    function test_submitClaim_FastPathRejectsStaleAmountsAndInvalidSignatures() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory firstSig = _signClaim(clientPk, jobId, FIVE_USDC, EMPTY_DELIVERABLE);

        vm.prank(provider);
        core.submitClaim(jobId, FIVE_USDC, EMPTY_DELIVERABLE, firstSig, "");

        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        vm.prank(provider);
        core.submitClaim(jobId, FIVE_USDC, EMPTY_DELIVERABLE, firstSig, "");

        bytes memory providerSig = _signClaim(providerPk, jobId, TEN_USDC, EMPTY_DELIVERABLE);
        vm.expectRevert(ERC8183.InvalidVoucherSignature.selector);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, providerSig, "");
    }

    function test_complete_ReleasesOnlyUnsettledEscrowAfterPartialSettlement() public {
        vm.prank(deployer);
        core.setPlatformFee(1000, deployer);
        vm.prank(deployer);
        core.setEvaluatorFee(500);

        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, EMPTY_DELIVERABLE);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, sig, "");
        vm.prank(provider);
        core.submit(jobId, bytes32("work"), "");

        vm.expectEmit(true, true, true, true, address(core));
        emit PlatformFeePaid(jobId, deployer, ONE_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit EvaluatorFeePaid(jobId, evaluator, 500_000);
        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, 8_500_000);
        vm.prank(evaluator);
        core.complete(jobId, bytes32("ok"), "");

        assertEq(usdc.balanceOf(deployer), 2_000_000);
        assertEq(usdc.balanceOf(evaluator), 1_000_000);
        assertEq(usdc.balanceOf(provider), 17_000_000);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_rejectAndClaimRefund_RefundOnlyUnsettledEscrowAfterPartialSettlement() public {
        (uint256 firstJobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory firstSig = _signClaim(clientPk, firstJobId, TEN_USDC, EMPTY_DELIVERABLE);
        vm.prank(provider);
        core.submitClaim(firstJobId, TEN_USDC, EMPTY_DELIVERABLE, firstSig, "");
        vm.prank(evaluator);
        core.reject(firstJobId, bytes32("no"), "");
        assertEq(usdc.balanceOf(client), TEN_USDC);

        usdc.mint(client, TWENTY_USDC);
        vm.prank(client);
        usdc.approve(address(core), TWENTY_USDC);

        uint48 expiry = _futureExpiry();
        vm.prank(client);
        uint256 secondJobId = core.createJob(provider, evaluator, expiry, "partial refund job", address(0), 0);
        vm.prank(provider);
        core.setBudget(secondJobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(secondJobId, TWENTY_USDC, "");

        bytes memory secondSig = _signClaim(clientPk, secondJobId, TEN_USDC, EMPTY_DELIVERABLE);
        vm.prank(provider);
        core.submitClaim(secondJobId, TEN_USDC, EMPTY_DELIVERABLE, secondSig, "");

        vm.warp(uint256(expiry) + 1);
        core.claimRefund(secondJobId);
        assertEq(usdc.balanceOf(client), 2 * TEN_USDC);
    }

    function test_submitClaim_ABI_LegacySettleEntryPointIsRemoved() public {
        (bool ok,) = address(core).call(abi.encodeWithSignature("settle(uint256,uint256,bytes,bytes)", 1, 1, "", ""));
        assertFalse(ok);
    }

    function test_submitClaim_FastPathZeroDeliverableSettlesInSameTx() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, EMPTY_DELIVERABLE);

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSubmitted(jobId, provider, TEN_USDC, TEN_USDC, EMPTY_DELIVERABLE);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, sig, "");

        assertEq(usdc.balanceOf(provider), TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    function test_submitClaim_SlowPathStoresHashAndEvaluatorApprovesWithDeliverable() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A, OPT_PARAMS_A);

        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSubmitted(jobId, provider, TEN_USDC, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, OPT_PARAMS_A);

        assertEq(usdc.balanceOf(provider), 0);
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, DELIVERABLE_A, OPT_PARAMS_A));

        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_A, OPT_PARAMS_B);

        vm.expectEmit(true, true, true, true, address(core));
        emit PaymentReleased(jobId, provider, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TEN_USDC, TEN_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimApproved(jobId, evaluator, TEN_USDC, TEN_USDC, DELIVERABLE_A);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_A, OPT_PARAMS_A);

        assertEq(usdc.balanceOf(provider), TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    function test_approveClaim_RevertsIfPreimageDoesNotMatchStoredHash() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");

        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_B, "");

        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.approveClaim(jobId, FIVE_USDC, DELIVERABLE_A, "");
    }

    function test_submitClaim_OnlyProviderCanSubmitSlowPath() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(outsider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(client);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");
    }

    function test_submitClaim_InvalidSignatureRevertsAnyPath() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory badSig = _signClaim(evaluatorPk, jobId, TEN_USDC, DELIVERABLE_A);

        vm.expectRevert(ERC8183.InvalidVoucherSignature.selector);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, badSig, "");
    }

    function test_submitClaim_RevertsOnceJobIsSubmitted() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        vm.prank(provider);
        core.submit(jobId, bytes32("work"), "");

        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, EMPTY_DELIVERABLE);
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, sig, "");
    }

    function test_approveClaim_ClientOrEvaluatorOnlyProviderSelfApproveReverts() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(provider);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_A, "");

        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimApproved(jobId, client, TEN_USDC, TEN_USDC, DELIVERABLE_A);
        vm.prank(client);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_A, "");
    }

    function test_approveClaim_RandomThirdPartyReverts() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(outsider);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_A, "");
    }

    function test_approveClaim_NoPendingClaimWhenNothingPending() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);

        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_A, "");
    }

    function test_approveClaim_RevertsOnceJobIsSubmitted() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");
        vm.prank(provider);
        core.submit(jobId, bytes32("work"), "");

        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(evaluator);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_A, "");
    }

    function test_submitClaim_SlowPathLatestClaimReplacesPendingHashAndInvalidatesOldApproval() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig1 = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig1, "");

        bytes memory sig2 = _signClaim(clientPk, jobId, TWENTY_USDC, DELIVERABLE_B);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSubmitted(jobId, provider, TWENTY_USDC, TWENTY_USDC, DELIVERABLE_B);
        vm.prank(provider);
        core.submitClaim(jobId, TWENTY_USDC, DELIVERABLE_B, sig2, "");

        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TWENTY_USDC, DELIVERABLE_B));
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(client);
        core.approveClaim(jobId, TEN_USDC, DELIVERABLE_A, "");
    }

    function test_submitClaim_SlowPathExactSubmittedHashCannotBeSubmittedAgainAfterRejection() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");
        vm.prank(evaluator);
        core.rejectClaim(jobId, TEN_USDC, DELIVERABLE_A, bytes32("rework"), "");

        vm.expectRevert(ERC8183.ClaimAlreadySubmitted.selector);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");
    }

    function test_submitClaim_HookDataFollowsCallerCumulativeDeliverableOptParamsPattern() public {
        MockHook hook = new MockHook();
        vm.prank(deployer);
        core.setHookWhitelist(address(hook), true);

        usdc.mint(client, TWENTY_USDC);
        vm.prank(client);
        usdc.approve(address(core), TWENTY_USDC);

        uint48 expiry = _futureExpiry();
        vm.prank(client);
        uint256 hookJobId = core.createJob(provider, evaluator, expiry, "hook claim job", address(hook), 0);
        vm.prank(provider);
        core.setBudget(hookJobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(hookJobId, TWENTY_USDC, "");

        bytes memory fastSig = _signClaim(clientPk, hookJobId, FIVE_USDC, EMPTY_DELIVERABLE);
        vm.prank(provider);
        core.submitClaim(hookJobId, FIVE_USDC, EMPTY_DELIVERABLE, fastSig, "");

        bytes memory slowSig = _signClaim(clientPk, hookJobId, TEN_USDC, DELIVERABLE_A, OPT_PARAMS_A);
        bytes memory expectedData = abi.encode(provider, TEN_USDC, DELIVERABLE_A, OPT_PARAMS_A);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BeforeAction(hookJobId, core.submitClaim.selector, expectedData);
        vm.prank(provider);
        core.submitClaim(hookJobId, TEN_USDC, DELIVERABLE_A, slowSig, OPT_PARAMS_A);
    }

    function test_rejectClaim_ClearsPendingProviderCanResubmitWithRevisedDeliverable() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");

        bytes32 reason = bytes32("rework");
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimRejected(jobId, evaluator, reason);
        vm.prank(evaluator);
        core.rejectClaim(jobId, TEN_USDC, DELIVERABLE_A, reason, "");
        assertEq(core.pendingClaimHash(jobId), bytes32(0));

        bytes memory sig2 = _signClaim(clientPk, jobId, FIVE_USDC, DELIVERABLE_B);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSubmitted(jobId, provider, FIVE_USDC, FIVE_USDC, DELIVERABLE_B);
        vm.prank(provider);
        core.submitClaim(jobId, FIVE_USDC, DELIVERABLE_B, sig2, "");
    }

    function test_rejectClaim_ProviderSelfRejectReverts() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(provider);
        core.rejectClaim(jobId, TEN_USDC, DELIVERABLE_A, bytes32(0), "");
    }

    function test_rejectClaim_RevertsOnceJobIsSubmitted() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig = _signClaim(clientPk, jobId, TEN_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "");
        vm.prank(provider);
        core.submit(jobId, bytes32("work"), "");

        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(evaluator);
        core.rejectClaim(jobId, TEN_USDC, DELIVERABLE_A, bytes32(0), "");
    }

    function test_submitClaim_FastPathDoesNotMutatePendingSlowClaim() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory slowSig = _signClaim(clientPk, jobId, FIVE_USDC, DELIVERABLE_A);
        vm.prank(provider);
        core.submitClaim(jobId, FIVE_USDC, DELIVERABLE_A, slowSig, "");
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(FIVE_USDC, DELIVERABLE_A));

        bytes memory fastSig = _signClaim(clientPk, jobId, TEN_USDC, EMPTY_DELIVERABLE);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, fastSig, "");

        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(FIVE_USDC, DELIVERABLE_A));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
    }

    function test_submitClaim_MonotonicSecondClaimMustExceedSettledAmount() public {
        (uint256 jobId,) = _createFundedJob(TWENTY_USDC);
        bytes memory sig1 = _signClaim(clientPk, jobId, TEN_USDC, EMPTY_DELIVERABLE);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, sig1, "");

        bytes memory stale = _signClaim(clientPk, jobId, FIVE_USDC, EMPTY_DELIVERABLE);
        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        vm.prank(provider);
        core.submitClaim(jobId, FIVE_USDC, EMPTY_DELIVERABLE, stale, "");

        bytes memory sig2 = _signClaim(clientPk, jobId, TEN_USDC + FIVE_USDC, EMPTY_DELIVERABLE);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSubmitted(jobId, provider, TEN_USDC + FIVE_USDC, FIVE_USDC, EMPTY_DELIVERABLE);
        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC + FIVE_USDC, EMPTY_DELIVERABLE, sig2, "");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ERC8183} from "../contracts/ERC8183.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {MockCBBTC} from "../contracts/mocks/MockCBBTC.sol";
import {MockFeeOnTransferToken} from "../contracts/mocks/MockFeeOnTransferToken.sol";

/// @notice Image Generation — E2E flow (no hook, core-only payment).
///         Mirrors the original Hardhat suite in test/ERC8183.test.js.
contract ERC8183Test is Test {
    uint256 constant TWENTY_USDC = 20_000_000; // 6 decimals
    uint256 constant ONE_CBBTC = 100_000_000;  // 8 decimals

    ERC8183 core;
    MockUSDC usdc;

    address deployer = makeAddr("deployer");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address evaluator = makeAddr("evaluator");

    // Events (must match ERC8183.sol exactly for vm.expectEmit)
    event ProviderSet(uint256 indexed jobId, address indexed provider, uint256 agentId);
    event BudgetSet(uint256 indexed jobId, address indexed token, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event PaymentTokenAllowlistUpdated(address indexed token, bool status);

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
        core.createJob(
            provider,
            evaluator,
            expiry,
            "Generate a beautiful landscape wallpaper image",
            address(0),
            0
        );
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
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                client,
                core.ADMIN_ROLE()
            )
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
}

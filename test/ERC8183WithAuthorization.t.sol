// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC8183} from "../contracts/ERC8183.sol";
import {ERC8183WithAuthorization} from "../contracts/ERC8183WithAuthorization.sol";
import {
    MockERC1271NonceObserver,
    MockERC1271Rejector
} from "../contracts/mocks/MockERC1271NonceObserver.sol";
import {MockCBBTC} from "../contracts/mocks/MockCBBTC.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";

contract ERC8183WithAuthorizationTest is Test {
    uint256 constant TWENTY_USDC = 20_000_000;
    uint256 constant TEN_USDC = 10_000_000;
    uint72 constant MAX_UINT72 = type(uint72).max;

    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant CREATE_JOB_AUTHORIZATION_TYPEHASH = keccak256(
        "CreateJobAuthorization(address signer,address provider,address evaluator,uint48 expiredAt,bytes32 descriptionHash,address hook,uint256 providerAgentId,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH = keccak256(
        "SetPayoutReceiverAuthorization(address signer,uint256 jobId,address payoutReceiver,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant SET_PROVIDER_AUTHORIZATION_TYPEHASH = keccak256(
        "SetProviderAuthorization(address signer,uint256 jobId,address provider,uint256 agentId,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant SET_BUDGET_AUTHORIZATION_TYPEHASH = keccak256(
        "SetBudgetAuthorization(address signer,uint256 jobId,address token,uint256 amount,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant FUND_AUTHORIZATION_TYPEHASH = keccak256(
        "FundAuthorization(address signer,uint256 jobId,address expectedToken,uint256 expectedBudget,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant SUBMIT_AUTHORIZATION_TYPEHASH = keccak256(
        "SubmitAuthorization(address signer,uint256 jobId,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant COMPLETE_AUTHORIZATION_TYPEHASH = keccak256(
        "CompleteAuthorization(address signer,uint256 jobId,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant REJECT_AUTHORIZATION_TYPEHASH = keccak256(
        "RejectAuthorization(address signer,uint256 jobId,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant SUBMIT_CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "SubmitClaimAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant SETTLE_CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "SettleClaimAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant APPROVE_CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "ApproveClaimAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 constant REJECT_CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "RejectClaimAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );

    ERC8183WithAuthorization core;
    MockUSDC usdc;

    address deployer = makeAddr("deployer");
    address client;
    uint256 clientPk;
    address provider;
    uint256 providerPk;
    address evaluator;
    uint256 evaluatorPk;
    address relayer = makeAddr("relayer");

    event AuthorizationUsed(address indexed signer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed signer, bytes32 indexed nonce);
    event PayoutReceiverSet(uint256 indexed jobId, address indexed actor, address indexed payoutReceiver);
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
        (client, clientPk) = makeAddrAndKey("client");
        (provider, providerPk) = makeAddrAndKey("provider");
        (evaluator, evaluatorPk) = makeAddrAndKey("evaluator");

        vm.startPrank(deployer);

        usdc = new MockUSDC();

        ERC8183WithAuthorization impl = new ERC8183WithAuthorization();
        bytes memory initData = abi.encodeCall(ERC8183WithAuthorization.initialize, (deployer, deployer));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        core = ERC8183WithAuthorization(address(proxy));

        core.setPaymentTokenAllowed(address(usdc), true);

        vm.stopPrank();

        usdc.mint(client, TWENTY_USDC);
        vm.prank(client);
        usdc.approve(address(core), TWENTY_USDC);
    }

    function _futureExpiry() internal view returns (uint48) {
        return uint48(block.timestamp + 3600);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 7200;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("ERC8183")),
                keccak256(bytes("1")),
                block.chainid,
                address(core)
            )
        );
    }

    function _sign(uint256 signerPk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _packNonce(address signer, uint72 nonce) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(signer)) << 96) | uint256(nonce));
    }

    function _assertPublicTypehash(string memory signature, bytes32 expected) internal view {
        (bool ok, bytes memory data) = address(core).staticcall(abi.encodeWithSignature(signature));

        assertTrue(ok);
        assertEq(abi.decode(data, (bytes32)), expected);
    }

    function _hashBytes(bytes memory value) internal pure returns (bytes32) {
        return keccak256(value);
    }

    function _hashString(string memory value) internal pure returns (bytes32) {
        return keccak256(bytes(value));
    }

    function _claimBindingHash(uint256 amount, bytes32 deliverable, bytes memory optParams)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(amount, deliverable, keccak256(optParams)));
    }

    function _auth(address signer, uint72 nonce, uint256 deadline, bytes memory sig)
        internal
        pure
        returns (ERC8183WithAuthorization.Authorization memory)
    {
        return ERC8183WithAuthorization.Authorization({signer: signer, nonce: nonce, deadline: deadline, sig: sig});
    }

    function _createParams(
        address provider_,
        address evaluator_,
        uint48 expiredAt,
        string memory description,
        address hook,
        uint256 providerAgentId
    ) internal pure returns (ERC8183WithAuthorization.CreateJobAuthorizationParams memory) {
        return ERC8183WithAuthorization.CreateJobAuthorizationParams({
                provider: provider_,
                evaluator: evaluator_,
                expiredAt: expiredAt,
                description: description,
                hook: hook,
                providerAgentId: providerAgentId,
                optParams: ""
            });
    }

    function _signCreateJob(
        uint256 signerPk,
        address signer,
        address provider_,
        address evaluator_,
        uint48 expiredAt,
        string memory description,
        address hook,
        uint256 providerAgentId,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    CREATE_JOB_AUTHORIZATION_TYPEHASH,
                    signer,
                    provider_,
                    evaluator_,
                    expiredAt,
                    _hashString(description),
                    hook,
                    providerAgentId,
                    _hashBytes(""),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSetPayoutReceiver(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        address payoutReceiver,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    payoutReceiver,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSetProvider(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        address provider_,
        uint256 agentId,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SET_PROVIDER_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    provider_,
                    agentId,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSetBudget(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        address token,
        uint256 amount,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SET_BUDGET_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    token,
                    amount,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signFund(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    FUND_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    expectedToken,
                    expectedBudget,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSubmit(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        bytes32 deliverable,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SUBMIT_AUTHORIZATION_TYPEHASH, signer, jobId, deliverable, _hashBytes(optParams), nonce, deadline
                )
            )
        );
    }

    function _signComplete(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        bytes32 reason,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    COMPLETE_AUTHORIZATION_TYPEHASH, signer, jobId, reason, _hashBytes(optParams), nonce, deadline
                )
            )
        );
    }

    function _signReject(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        bytes32 reason,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    REJECT_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    reason,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSubmitClaim(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SUBMIT_CLAIM_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signSettleClaim(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    SETTLE_CLAIM_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signApproveClaim(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    APPROVE_CLAIM_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _signRejectClaim(
        uint256 signerPk,
        address signer,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 reason,
        bytes memory optParams,
        uint72 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _sign(
            signerPk,
            keccak256(
                abi.encode(
                    REJECT_CLAIM_AUTHORIZATION_TYPEHASH,
                    signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    reason,
                    _hashBytes(optParams),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _createFundedJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(provider, evaluator, _futureExpiry(), "claim auth job", address(0), 0, "");
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), TWENTY_USDC, "");
    }

    function _relayCreateJob(
        address signer,
        uint256 signerPk,
        address provider_,
        address evaluator_,
        uint48 expiry,
        string memory description,
        uint72 nonce,
        uint256 deadline
    ) internal returns (uint256 jobId) {
        bytes memory sig = _signCreateJob(
            signerPk, signer, provider_, evaluator_, expiry, description, address(0), 0, nonce, deadline
        );
        vm.prank(relayer);
        jobId = core.createJobWithAuthorization(
            _createParams(provider_, evaluator_, expiry, description, address(0), 0),
            _auth(signer, nonce, deadline, sig)
        );
    }

    function _relaySetBudget(uint256 jobId, uint72 nonce, uint256 deadline) internal {
        bytes memory sig = _signSetBudget(providerPk, provider, jobId, address(usdc), TWENTY_USDC, "", nonce, deadline);
        vm.prank(relayer);
        core.setBudgetWithAuthorization(jobId, address(usdc), TWENTY_USDC, "", _auth(provider, nonce, deadline, sig));
    }

    function _relayFund(uint256 jobId, uint72 nonce, uint256 deadline) internal {
        bytes memory sig = _signFund(clientPk, client, jobId, address(usdc), TWENTY_USDC, "", nonce, deadline);
        vm.prank(relayer);
        core.fundWithAuthorization(jobId, address(usdc), TWENTY_USDC, "", _auth(client, nonce, deadline, sig));
    }

    function _relaySubmit(uint256 jobId, bytes32 deliverable, uint72 nonce, uint256 deadline) internal {
        bytes memory sig = _signSubmit(providerPk, provider, jobId, deliverable, "", nonce, deadline);
        vm.prank(relayer);
        core.submitWithAuthorization(jobId, deliverable, "", _auth(provider, nonce, deadline, sig));
    }

    function _relayComplete(uint256 jobId, bytes32 reason, uint72 nonce, uint256 deadline) internal {
        bytes memory sig = _signComplete(evaluatorPk, evaluator, jobId, reason, "", nonce, deadline);
        vm.prank(relayer);
        core.completeWithAuthorization(jobId, reason, "", _auth(evaluator, nonce, deadline, sig));
    }

    function test_domainSeparatorUsesERC8183ProtocolDomain() public view {
        assertEq(core.DOMAIN_SEPARATOR(), _domainSeparator());
    }

    function test_claimAuthorizationTypehashesArePublic() public view {
        _assertPublicTypehash("SET_PROVIDER_AUTHORIZATION_TYPEHASH()", SET_PROVIDER_AUTHORIZATION_TYPEHASH);
        _assertPublicTypehash("FUND_AUTHORIZATION_TYPEHASH()", FUND_AUTHORIZATION_TYPEHASH);
        _assertPublicTypehash("REJECT_AUTHORIZATION_TYPEHASH()", REJECT_AUTHORIZATION_TYPEHASH);
        _assertPublicTypehash("SUBMIT_CLAIM_AUTHORIZATION_TYPEHASH()", SUBMIT_CLAIM_AUTHORIZATION_TYPEHASH);
        _assertPublicTypehash("SETTLE_CLAIM_AUTHORIZATION_TYPEHASH()", SETTLE_CLAIM_AUTHORIZATION_TYPEHASH);
        _assertPublicTypehash("APPROVE_CLAIM_AUTHORIZATION_TYPEHASH()", APPROVE_CLAIM_AUTHORIZATION_TYPEHASH);
        _assertPublicTypehash("REJECT_CLAIM_AUTHORIZATION_TYPEHASH()", REJECT_CLAIM_AUTHORIZATION_TYPEHASH);
    }

    function test_upgradeInitializerSetsERC8183DomainForAuthorizationExtension() public {
        vm.startPrank(deployer);
        ERC8183 baseImpl = new ERC8183();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(baseImpl), abi.encodeCall(ERC8183.initialize, (deployer, deployer)));
        ERC8183 base = ERC8183(address(proxy));
        base.setPaymentTokenAllowed(address(usdc), true);

        ERC8183WithAuthorization authImpl = new ERC8183WithAuthorization();
        base.upgradeToAndCall(
            address(authImpl), abi.encodeCall(ERC8183WithAuthorization.initializeAuthorizationV2, ())
        );
        vm.stopPrank();

        core = ERC8183WithAuthorization(address(proxy));
        vm.prank(client);
        usdc.approve(address(core), TWENTY_USDC);

        assertEq(core.DOMAIN_SEPARATOR(), _domainSeparator());

        uint256 deadline = _deadline();
        uint256 jobId =
            _relayCreateJob(client, clientPk, provider, evaluator, _futureExpiry(), "upgraded auth job", 51, deadline);

        assertEq(core.getJob(jobId).client, client);
        assertTrue(core.authorizationNonceUsed(_packNonce(client, 51)));
    }

    function test_relaysFullSignedJobFlow() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "authorization image job";

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(client, _packNonce(client, 1));
        uint256 jobId = _relayCreateJob(client, clientPk, provider, evaluator, expiry, description, 1, deadline);

        assertEq(core.getJob(jobId).client, client);

        _relaySetBudget(jobId, 2, deadline);
        _relayFund(jobId, 3, deadline);

        bytes32 deliverable = bytes32("done");
        _relaySubmit(jobId, deliverable, 4, deadline);

        bytes32 reason = bytes32("approved");
        _relayComplete(jobId, reason, 5, deadline);

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
    }

    function test_fundWithAuthorization_RevertsWhenPaymentTokenChangesAfterSigning() public {
        MockCBBTC cbbtc = new MockCBBTC();

        vm.prank(deployer);
        core.setPaymentTokenAllowed(address(cbbtc), true);

        cbbtc.mint(client, TWENTY_USDC);
        vm.prank(client);
        cbbtc.approve(address(core), TWENTY_USDC);

        uint256 deadline = _deadline();
        uint256 jobId =
            _relayCreateJob(client, clientPk, provider, evaluator, _futureExpiry(), "fund token binding", 65, deadline);

        vm.prank(provider);
        core.setBudget(jobId, address(usdc), TWENTY_USDC, "");

        uint72 nonce = 66;
        bytes memory sig = _signFund(clientPk, client, jobId, address(usdc), TWENTY_USDC, "", nonce, deadline);

        vm.prank(provider);
        core.setBudget(jobId, address(cbbtc), TWENTY_USDC, "");

        vm.expectRevert(ERC8183.PaymentTokenMismatch.selector);
        vm.prank(relayer);
        core.fundWithAuthorization(jobId, address(usdc), TWENTY_USDC, "", _auth(client, nonce, deadline, sig));

        assertFalse(core.authorizationNonceUsed(_packNonce(client, nonce)));
        assertEq(usdc.balanceOf(address(core)), 0);
        assertEq(cbbtc.balanceOf(address(core)), 0);
    }

    function test_createJobWithAuthorizationLeavesPayoutReceiverUnset() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "authorization receiver job";
        uint72 nonce = 6;

        assertEq(core.CREATE_JOB_AUTHORIZATION_TYPEHASH(), CREATE_JOB_AUTHORIZATION_TYPEHASH);

        bytes memory sig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, description, address(0), 0, nonce, deadline
        );

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(client, _packNonce(client, nonce));
        vm.prank(relayer);
        uint256 jobId = core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, description, address(0), 0),
            _auth(client, nonce, deadline, sig)
        );

        ERC8183.Job memory job = core.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.payoutReceiver, address(0));
    }

    function test_setPayoutReceiverWithAuthorization_ProviderOnlyOpenOnlyAndLocksAfterFund() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint256 jobId = _relayCreateJob(client, clientPk, provider, evaluator, expiry, "receiver auth job", 1, deadline);
        address plainReceiver = makeAddr("plainReceiver");
        address secondReceiver = makeAddr("secondReceiver");

        assertEq(core.SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH(), SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH);

        bytes memory clientSig = _signSetPayoutReceiver(clientPk, client, jobId, plainReceiver, "", 2, deadline);
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(relayer);
        core.setPayoutReceiverWithAuthorization(jobId, plainReceiver, "", _auth(client, 2, deadline, clientSig));

        bytes memory providerSig = _signSetPayoutReceiver(providerPk, provider, jobId, plainReceiver, "", 3, deadline);
        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(provider, _packNonce(provider, 3));
        vm.expectEmit(true, true, true, true, address(core));
        emit PayoutReceiverSet(jobId, provider, plainReceiver);
        vm.prank(relayer);
        core.setPayoutReceiverWithAuthorization(jobId, plainReceiver, "", _auth(provider, 3, deadline, providerSig));

        assertEq(core.getJob(jobId).payoutReceiver, plainReceiver);

        _relaySetBudget(jobId, 4, deadline);
        _relayFund(jobId, 5, deadline);

        bytes memory lockedSig = _signSetPayoutReceiver(providerPk, provider, jobId, secondReceiver, "", 6, deadline);
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(relayer);
        core.setPayoutReceiverWithAuthorization(jobId, secondReceiver, "", _auth(provider, 6, deadline, lockedSig));
    }

    function test_setPayoutReceiverWithAuthorization_bindsOptParams() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint256 jobId = _relayCreateJob(client, clientPk, provider, evaluator, expiry, "receiver optparams", 1, deadline);
        address receiver = makeAddr("optParamsReceiver");

        // Signature over optParams = 0x01; relaying with 0x02 must fail.
        bytes memory sig = _signSetPayoutReceiver(providerPk, provider, jobId, receiver, hex"01", 2, deadline);
        vm.prank(relayer);
        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        core.setPayoutReceiverWithAuthorization(jobId, receiver, hex"02", _auth(provider, 2, deadline, sig));

        // Matching optParams succeeds.
        vm.prank(relayer);
        core.setPayoutReceiverWithAuthorization(jobId, receiver, hex"01", _auth(provider, 2, deadline, sig));
        assertEq(core.getJob(jobId).payoutReceiver, receiver);
    }

    function test_createJobWithAuthorization_bindsOptParams() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "createjob optparams";

        // Sign over optParams = 0x01.
        bytes memory sig = _sign(
            clientPk,
            keccak256(
                abi.encode(
                    CREATE_JOB_AUTHORIZATION_TYPEHASH,
                    client,
                    provider,
                    evaluator,
                    expiry,
                    _hashString(description),
                    address(0),
                    uint256(0),
                    _hashBytes(hex"01"),
                    uint72(70),
                    deadline
                )
            )
        );

        ERC8183WithAuthorization.CreateJobAuthorizationParams memory paramsWrong = ERC8183WithAuthorization
            .CreateJobAuthorizationParams({
            provider: provider,
            evaluator: evaluator,
            expiredAt: expiry,
            description: description,
            hook: address(0),
            providerAgentId: 0,
            optParams: hex"02"
        });
        vm.prank(relayer);
        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        core.createJobWithAuthorization(paramsWrong, _auth(client, 70, deadline, sig));

        ERC8183WithAuthorization.CreateJobAuthorizationParams memory paramsRight = ERC8183WithAuthorization
            .CreateJobAuthorizationParams({
            provider: provider,
            evaluator: evaluator,
            expiredAt: expiry,
            description: description,
            hook: address(0),
            providerAgentId: 0,
            optParams: hex"01"
        });
        vm.prank(relayer);
        uint256 jobId = core.createJobWithAuthorization(paramsRight, _auth(client, 70, deadline, sig));
        assertEq(core.getJob(jobId).provider, provider);
    }

    function test_relaysClientAuthorizedSetProvider() public {
        vm.prank(client);
        uint256 jobId = core.createJob(address(0), evaluator, _futureExpiry(), "late provider", address(0), 0, "");
        uint256 deadline = _deadline();
        uint256 agentId = 7;
        bytes memory sig = _signSetProvider(clientPk, client, jobId, provider, agentId, "", 61, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(client, _packNonce(client, 61));
        vm.prank(relayer);
        core.setProviderWithAuthorization(jobId, provider, agentId, "", _auth(client, 61, deadline, sig));

        assertEq(core.getJob(jobId).provider, provider);
        assertEq(core.getJob(jobId).providerAgentId, agentId);
        assertTrue(core.authorizationNonceUsed(_packNonce(client, 61)));
    }

    function test_setProviderWithAuthorization_bindsOptParams() public {
        vm.prank(client);
        uint256 jobId = core.createJob(address(0), evaluator, _futureExpiry(), "late provider", address(0), 0, "");
        uint256 deadline = _deadline();
        uint256 agentId = 7;

        // Signature is over optParams = 0x01; relaying with 0x02 must fail.
        bytes memory sig = _signSetProvider(clientPk, client, jobId, provider, agentId, hex"01", 62, deadline);
        vm.prank(relayer);
        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        core.setProviderWithAuthorization(jobId, provider, agentId, hex"02", _auth(client, 62, deadline, sig));

        // Matching optParams succeeds and records the signer as actor.
        vm.prank(relayer);
        core.setProviderWithAuthorization(jobId, provider, agentId, hex"01", _auth(client, 62, deadline, sig));
        assertEq(core.getJob(jobId).provider, provider);
    }

    function test_relaysEvaluatorAuthorizedReject() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        bytes32 reason = "rejected";
        bytes memory sig = _signReject(evaluatorPk, evaluator, jobId, reason, "", 62, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(evaluator, _packNonce(evaluator, 62));
        vm.prank(relayer);
        core.rejectWithAuthorization(jobId, reason, "", _auth(evaluator, 62, deadline, sig));

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
        assertTrue(core.authorizationNonceUsed(_packNonce(evaluator, 62)));
    }

    function test_relaysProviderAuthorizedClaimIntoPendingStateAndApproval() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        bytes memory optParams = hex"1234";
        bytes32 deliverable = bytes32("milestone-1");

        bytes memory submitClaimSig =
            _signSubmitClaim(providerPk, provider, jobId, TEN_USDC, deliverable, optParams, 21, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(provider, _packNonce(provider, 21));
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSubmitted(jobId, provider, TEN_USDC, TEN_USDC, deliverable, optParams);
        vm.prank(relayer);
        core.submitClaimWithAuthorization(
            jobId, TEN_USDC, deliverable, optParams, _auth(provider, 21, deadline, submitClaimSig)
        );

        assertEq(core.getJob(jobId).settledAmount, 0);
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, deliverable, optParams));
        assertEq(usdc.balanceOf(provider), 0);

        bytes memory approveClaimSig =
            _signApproveClaim(evaluatorPk, evaluator, jobId, TEN_USDC, deliverable, optParams, 22, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(evaluator, _packNonce(evaluator, 22));
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimApproved(jobId, evaluator, TEN_USDC, TEN_USDC, deliverable);
        vm.prank(relayer);
        core.approveClaimWithAuthorization(
            jobId, TEN_USDC, deliverable, optParams, _auth(evaluator, 22, deadline, approveClaimSig)
        );

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
    }

    function test_relaysProviderAuthorizedClaimRejectionClearsPendingState() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        bytes32 deliverable = bytes32("milestone-1");
        bytes32 reason = bytes32("withdrawn");

        bytes memory submitClaimSig = _signSubmitClaim(providerPk, provider, jobId, TEN_USDC, deliverable, "", 24, deadline);
        vm.prank(relayer);
        core.submitClaimWithAuthorization(jobId, TEN_USDC, deliverable, "", _auth(provider, 24, deadline, submitClaimSig));

        bytes memory rejectClaimSig =
            _signRejectClaim(providerPk, provider, jobId, TEN_USDC, deliverable, reason, "", 25, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(provider, _packNonce(provider, 25));
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimRejected(jobId, provider, reason);
        vm.prank(relayer);
        core.rejectClaimWithAuthorization(
            jobId, TEN_USDC, deliverable, reason, "", _auth(provider, 25, deadline, rejectClaimSig)
        );

        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    function test_relaysClientAuthorizedSettleClaimFastPath() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        bytes32 deliverable = bytes32(0);

        bytes memory settleClaimSig =
            _signSettleClaim(clientPk, client, jobId, TEN_USDC, deliverable, "", 23, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(client, _packNonce(client, 23));
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSettled(jobId, client, TEN_USDC, TEN_USDC, deliverable);
        vm.prank(relayer);
        core.settleClaimWithAuthorization(
            jobId, TEN_USDC, deliverable, "", _auth(client, 23, deadline, settleClaimSig)
        );

        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(provider), TEN_USDC);
    }

    function test_claimAuthorizationRejectsCrossFunctionReplayWithSameLayout() public {
        uint256 jobId = _createFundedJob();
        uint256 deadline = _deadline();
        bytes32 deliverable = bytes32("milestone-1");
        uint72 nonce = 67;

        vm.prank(provider);
        core.submitClaim(jobId, TEN_USDC, deliverable, "");

        bytes memory settleSig = _signSettleClaim(clientPk, client, jobId, TEN_USDC, deliverable, "", nonce, deadline);

        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.approveClaimWithAuthorization(jobId, TEN_USDC, deliverable, "", _auth(client, nonce, deadline, settleSig));

        assertFalse(core.authorizationNonceUsed(_packNonce(client, nonce)));
        assertEq(core.pendingClaimHash(jobId), _claimBindingHash(TEN_USDC, deliverable, ""));
        assertEq(core.getJob(jobId).settledAmount, 0);
    }

    function test_rejectsReplayedAuthorizations() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "replay test";
        uint72 authNonce = 11;
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory sig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, description, address(0), 0, authNonce, deadline
        );
        ERC8183WithAuthorization.Authorization memory auth = _auth(client, authNonce, deadline, sig);

        vm.prank(relayer);
        core.createJobWithAuthorization(params, auth);
        assertTrue(core.authorizationNonceUsed(_packNonce(client, authNonce)));

        vm.expectRevert(ERC8183WithAuthorization.AuthorizationNonceUsed.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, auth);
    }

    function test_rejectsExpiredAuthorizations() public {
        uint48 expiry = _futureExpiry();
        uint256 expiredDeadline = block.timestamp - 1;
        uint72 expiredNonce = 12;
        bytes memory expiredSig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, "expired", address(0), 0, expiredNonce, expiredDeadline
        );
        vm.expectRevert(ERC8183WithAuthorization.AuthorizationExpired.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, "expired", address(0), 0),
            _auth(client, expiredNonce, expiredDeadline, expiredSig)
        );
    }

    function test_rejectsTamperedAuthorizations() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 tamperedNonce = 13;
        bytes memory tamperedSig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, "signed", address(0), 0, tamperedNonce, deadline
        );
        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(
            _createParams(provider, evaluator, expiry, "tampered", address(0), 0),
            _auth(client, tamperedNonce, deadline, tamperedSig)
        );
        assertFalse(core.authorizationNonceUsed(_packNonce(client, tamperedNonce)));
    }

    function test_reservesPackedNonceBeforeERC1271SignatureValidation() public {
        MockERC1271NonceObserver contractSigner = new MockERC1271NonceObserver();
        address signer = address(contractSigner);
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 nonce = 31;
        bytes32 packed = _packNonce(signer, nonce);
        string memory description = "erc1271 nonce reservation";
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory sig = abi.encode(address(core), packed);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(signer, packed);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(signer, nonce, deadline, sig));

        assertTrue(core.authorizationNonceUsed(packed));
        assertEq(core.getJob(1).client, signer);
    }

    function test_rejectsERC1271InvalidSignatureAndRollsBackNonce() public {
        MockERC1271Rejector contractSigner = new MockERC1271Rejector();
        address signer = address(contractSigner);
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 nonce = 32;
        bytes32 packed = _packNonce(signer, nonce);
        string memory description = "erc1271 invalid";
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);

        vm.expectRevert(ERC8183WithAuthorization.InvalidAuthorizationSignature.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(signer, nonce, deadline, hex""));

        assertFalse(core.authorizationNonceUsed(packed));
        assertEq(core.jobCounter(), 0);
    }

    function test_acceptsMaximumUint72NonceAndStoresPackedKey() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "max nonce";
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory sig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, description, address(0), 0, MAX_UINT72, deadline
        );
        bytes32 packed = _packNonce(client, MAX_UINT72);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(client, packed);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(client, MAX_UINT72, deadline, sig));

        assertTrue(core.authorizationNonceUsed(packed));
    }

    function test_allowsDifferentSignersToUseSameNumericNonce() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        string memory description = "shared nonce";
        uint72 sharedNonce = 42;
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory createSig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, description, address(0), 0, sharedNonce, deadline
        );

        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(client, sharedNonce, deadline, createSig));

        uint256 jobId = 1;
        bytes memory setBudgetSig =
            _signSetBudget(providerPk, provider, jobId, address(usdc), TWENTY_USDC, "", sharedNonce, deadline);

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationUsed(provider, _packNonce(provider, sharedNonce));
        vm.prank(relayer);
        core.setBudgetWithAuthorization(
            jobId, address(usdc), TWENTY_USDC, "", _auth(provider, sharedNonce, deadline, setBudgetSig)
        );

        assertTrue(core.authorizationNonceUsed(_packNonce(client, sharedNonce)));
        assertTrue(core.authorizationNonceUsed(_packNonce(provider, sharedNonce)));
    }

    function test_cancelAuthorizationBurnsSignerNonce() public {
        uint48 expiry = _futureExpiry();
        uint256 deadline = _deadline();
        uint72 nonce = 63;
        string memory description = "cancelled";
        ERC8183WithAuthorization.CreateJobAuthorizationParams memory params =
            _createParams(provider, evaluator, expiry, description, address(0), 0);
        bytes memory sig = _signCreateJob(
            clientPk, client, provider, evaluator, expiry, description, address(0), 0, nonce, deadline
        );

        vm.expectEmit(true, true, true, true, address(core));
        emit AuthorizationCanceled(client, _packNonce(client, nonce));
        vm.prank(client);
        core.cancelAuthorization(nonce);

        assertTrue(core.authorizationNonceUsed(_packNonce(client, nonce)));

        vm.expectRevert(ERC8183WithAuthorization.AuthorizationNonceUsed.selector);
        vm.prank(relayer);
        core.createJobWithAuthorization(params, _auth(client, nonce, deadline, sig));
    }

    function test_cancelAuthorizationRejectsUsedNonce() public {
        uint72 nonce = 64;

        vm.prank(client);
        core.cancelAuthorization(nonce);

        vm.expectRevert(ERC8183WithAuthorization.AuthorizationNonceUsed.selector);
        vm.prank(client);
        core.cancelAuthorization(nonce);
    }
}

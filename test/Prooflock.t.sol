// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Prooflock} from "../src/Prooflock.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract ProoflockTest is Test {
    Prooflock internal lock;
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal feeTo = makeAddr("feeTo");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AMOUNT = 1_000e6;
    uint256 internal constant BOND = 100e6;
    bytes32 internal constant HASH = keccak256("deliverable");

    function setUp() public {
        usdc = new MockUSDC();
        lock = new Prooflock(address(usdc), owner, feeTo);
        usdc.mint(client, 10_000e6);
        usdc.mint(provider, 10_000e6);
        vm.prank(client);
        usdc.approve(address(lock), type(uint256).max);
        vm.prank(provider);
        usdc.approve(address(lock), type(uint256).max);
    }

    function _params(address arb, uint256 bond) internal view returns (Prooflock.JobParams memory p) {
        p.provider = provider;
        p.arbiter = arb;
        p.amount = AMOUNT;
        p.deadline = uint64(block.timestamp + 7 days);
        p.reviewWindow = 3 days;
        p.bondRequired = bond;
        p.clientAgentId = 11;
        p.providerAgentId = 22;
        p.metadataURI = "ipfs://job";
    }

    function _create(address arb, uint256 bond) internal returns (uint256 id) {
        vm.prank(client);
        id = lock.createJob(_params(arb, bond));
    }

    function _createAndDeliver(address arb, uint256 bond) internal returns (uint256 id) {
        id = _create(arb, bond);
        if (bond > 0) {
            vm.prank(provider);
            lock.postBond(id);
        }
        vm.prank(provider);
        lock.deliver(id, HASH, "ipfs://out");
    }

    // ── create ───────────────────────────────────────────────────────────────

    function test_createJob_fundsAndIndexes() public {
        uint256 id = _create(arbiter, BOND);
        assertEq(id, 1);
        assertEq(lock.nextJobId(), 2);
        Prooflock.Job memory job = lock.jobs(id);
        assertEq(job.client, client);
        assertEq(job.provider, provider);
        assertEq(job.arbiter, arbiter);
        assertEq(job.amount, AMOUNT);
        assertEq(job.bondRequired, BOND);
        assertEq(job.bondDeposited, 0);
        assertEq(job.feeBps, 0);
        assertEq(job.clientAgentId, 11);
        assertEq(job.providerAgentId, 22);
        assertEq(job.metadataURI, "ipfs://job");
        assertEq(uint8(job.status), uint8(Prooflock.Status.Funded));
        assertEq(usdc.balanceOf(address(lock)), AMOUNT);
        assertEq(lock.totalLocked(), AMOUNT);
        assertEq(lock.jobsOf(client).length, 1);
        assertEq(lock.jobsOf(provider)[0], 1);
    }

    function test_createJob_revertsZeroAmount() public {
        Prooflock.JobParams memory p = _params(arbiter, 0);
        p.amount = 0;
        vm.prank(client);
        vm.expectRevert(Prooflock.ZeroAmount.selector);
        lock.createJob(p);
    }

    function test_createJob_revertsBadProvider() public {
        Prooflock.JobParams memory p = _params(arbiter, 0);
        p.provider = address(0);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidProvider.selector);
        lock.createJob(p);
        p.provider = client;
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidProvider.selector);
        lock.createJob(p);
    }

    function test_createJob_revertsBadArbiter() public {
        Prooflock.JobParams memory p = _params(client, 0);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidArbiter.selector);
        lock.createJob(p);
        p.arbiter = provider;
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidArbiter.selector);
        lock.createJob(p);
    }

    function test_createJob_revertsBadDeadline() public {
        Prooflock.JobParams memory p = _params(address(0), 0);
        p.deadline = uint64(block.timestamp + 30 minutes);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidDeadline.selector);
        lock.createJob(p);
        p.deadline = uint64(block.timestamp + 181 days);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidDeadline.selector);
        lock.createJob(p);
    }

    function test_createJob_revertsBadReviewWindow() public {
        Prooflock.JobParams memory p = _params(address(0), 0);
        p.reviewWindow = 30 minutes;
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidReviewWindow.selector);
        lock.createJob(p);
        p.reviewWindow = 31 days;
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidReviewWindow.selector);
        lock.createJob(p);
    }

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert(Prooflock.ZeroAddress.selector);
        new Prooflock(address(0), owner, feeTo);
        vm.expectRevert(Prooflock.ZeroAddress.selector);
        new Prooflock(address(usdc), address(0), feeTo);
        vm.expectRevert(Prooflock.ZeroAddress.selector);
        new Prooflock(address(usdc), owner, address(0));
    }

    // ── bond + deliver ───────────────────────────────────────────────────────

    function test_postBond_andDeliver() public {
        uint256 id = _create(arbiter, BOND);
        vm.prank(provider);
        lock.postBond(id);
        assertEq(lock.jobs(id).bondDeposited, BOND);
        assertEq(lock.totalLocked(), AMOUNT + BOND);
        assertEq(usdc.balanceOf(address(lock)), AMOUNT + BOND);
        vm.prank(provider);
        lock.deliver(id, HASH, "ipfs://out");
        Prooflock.Job memory job = lock.jobs(id);
        assertEq(uint8(job.status), uint8(Prooflock.Status.Delivered));
        assertEq(job.deliverableHash, HASH);
        assertEq(job.deliverableURI, "ipfs://out");
        assertEq(job.reviewDeadline, uint64(block.timestamp) + 3 days);
    }

    function test_postBond_revertsIfNotRequired() public {
        uint256 id = _create(address(0), 0);
        vm.prank(provider);
        vm.expectRevert(Prooflock.BondNotRequired.selector);
        lock.postBond(id);
    }

    function test_postBond_revertsIfNotProvider() public {
        uint256 id = _create(address(0), BOND);
        vm.prank(stranger);
        vm.expectRevert(Prooflock.NotProvider.selector);
        lock.postBond(id);
    }

    function test_postBond_revertsTwice() public {
        uint256 id = _create(address(0), BOND);
        vm.prank(provider);
        lock.postBond(id);
        vm.prank(provider);
        vm.expectRevert(Prooflock.BondAlreadyPosted.selector);
        lock.postBond(id);
    }

    function test_postBond_revertsAfterDeadline() public {
        uint256 id = _create(address(0), BOND);
        vm.warp(lock.jobs(id).deadline);
        vm.prank(provider);
        vm.expectRevert(Prooflock.DeadlinePassed.selector);
        lock.postBond(id);
    }

    function test_deliver_revertsWithoutBond() public {
        uint256 id = _create(address(0), BOND);
        vm.prank(provider);
        vm.expectRevert(Prooflock.BondNotPosted.selector);
        lock.deliver(id, HASH, "");
    }

    function test_deliver_revertsAfterDeadline() public {
        uint256 id = _create(address(0), 0);
        vm.warp(lock.jobs(id).deadline);
        vm.prank(provider);
        vm.expectRevert(Prooflock.DeadlinePassed.selector);
        lock.deliver(id, HASH, "");
    }

    function test_deliver_revertsEmptyHash() public {
        uint256 id = _create(address(0), 0);
        vm.prank(provider);
        vm.expectRevert(Prooflock.EmptyDeliverable.selector);
        lock.deliver(id, bytes32(0), "ipfs://x");
    }

    function test_deliver_revertsNotProvider() public {
        uint256 id = _create(address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(Prooflock.NotProvider.selector);
        lock.deliver(id, HASH, "");
    }

    function test_deliver_allowedWithoutBondWhenNotRequired() public {
        uint256 id = _create(address(0), 0);
        vm.prank(provider);
        lock.deliver(id, HASH, "");
        assertEq(uint8(lock.jobs(id).status), uint8(Prooflock.Status.Delivered));
    }

    // ── accept / auto-release ────────────────────────────────────────────────

    function test_accept_paysProviderReturnsBond() public {
        uint256 id = _createAndDeliver(arbiter, BOND);
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(client);
        lock.accept(id);
        Prooflock.Job memory job = lock.jobs(id);
        assertEq(uint8(job.status), uint8(Prooflock.Status.Released));
        assertEq(job.amount, 0);
        assertEq(job.bondDeposited, 0);
        assertEq(lock.totalLocked(), 0);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(usdc.balanceOf(client), clientBefore);
        assertEq(usdc.balanceOf(provider), providerBefore + AMOUNT + BOND);
        assertTrue(lock.isTerminal(job.status));
    }

    function test_accept_takesSnapshottedFee() public {
        vm.prank(owner);
        lock.setFeeBps(200); // 2%
        uint256 id = _createAndDeliver(address(0), 0);
        // later fee change must not affect this job
        vm.prank(owner);
        lock.setFeeBps(500);
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeTo);
        vm.prank(client);
        lock.accept(id);
        uint256 fee = (AMOUNT * 200) / 10_000;
        assertEq(usdc.balanceOf(provider), providerBefore + AMOUNT - fee);
        assertEq(usdc.balanceOf(feeTo), feeBefore + fee);
        assertEq(lock.jobs(id).feeBps, 200);
        assertEq(lock.totalLocked(), 0);
    }

    function test_accept_revertsNotClient() public {
        uint256 id = _createAndDeliver(address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(Prooflock.NotClient.selector);
        lock.accept(id);
    }

    function test_accept_revertsDouble() public {
        uint256 id = _createAndDeliver(address(0), 0);
        vm.prank(client);
        lock.accept(id);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.accept(id);
    }

    function test_autoRelease_afterReviewWindow() public {
        uint256 id = _createAndDeliver(address(0), BOND);
        vm.warp(lock.jobs(id).reviewDeadline);
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(stranger);
        lock.autoRelease(id);
        assertEq(uint8(lock.jobs(id).status), uint8(Prooflock.Status.Released));
        assertEq(usdc.balanceOf(provider), providerBefore + AMOUNT + BOND);
        assertEq(lock.totalLocked(), 0);
    }

    function test_autoRelease_revertsTooEarly() public {
        uint256 id = _createAndDeliver(address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(Prooflock.ReviewWindowOpen.selector);
        lock.autoRelease(id);
        vm.warp(lock.jobs(id).reviewDeadline - 1);
        vm.prank(stranger);
        vm.expectRevert(Prooflock.ReviewWindowOpen.selector);
        lock.autoRelease(id);
    }

    // ── refund ───────────────────────────────────────────────────────────────

    function test_refund_afterMissedDeadline_returnsBond() public {
        uint256 id = _create(arbiter, BOND);
        vm.prank(provider);
        lock.postBond(id);
        vm.warp(lock.jobs(id).deadline);
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(stranger);
        lock.refund(id);
        assertEq(uint8(lock.jobs(id).status), uint8(Prooflock.Status.Refunded));
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT);
        assertEq(usdc.balanceOf(provider), providerBefore + BOND);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);
    }

    function test_refund_revertsBeforeDeadline() public {
        uint256 id = _create(address(0), 0);
        vm.expectRevert(Prooflock.DeadlineNotReached.selector);
        lock.refund(id);
    }

    function test_refund_revertsAfterDeliver() public {
        uint256 id = _createAndDeliver(address(0), 0);
        vm.warp(lock.jobs(id).deadline);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.refund(id);
    }

    function test_refund_noBondPath() public {
        uint256 id = _create(address(0), 0);
        vm.warp(lock.jobs(id).deadline);
        uint256 clientBefore = usdc.balanceOf(client);
        lock.refund(id);
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT);
        assertEq(lock.totalLocked(), 0);
    }

    // ── dispute + resolve ────────────────────────────────────────────────────

    function test_dispute_andResolvePay() public {
        uint256 id = _createAndDeliver(arbiter, BOND);
        vm.prank(client);
        lock.dispute(id);
        assertEq(uint8(lock.jobs(id).status), uint8(Prooflock.Status.Disputed));
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(arbiter);
        lock.resolve(id, AMOUNT, false);
        assertEq(uint8(lock.jobs(id).status), uint8(Prooflock.Status.Resolved));
        assertEq(usdc.balanceOf(provider), providerBefore + AMOUNT + BOND);
        assertEq(lock.totalLocked(), 0);
    }

    function test_dispute_andResolveRefundSlashBond() public {
        uint256 id = _createAndDeliver(arbiter, BOND);
        vm.prank(client);
        lock.dispute(id);
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(arbiter);
        lock.resolve(id, 0, true);
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + BOND);
        assertEq(usdc.balanceOf(provider), providerBefore);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);
    }

    function test_dispute_andResolveSplit() public {
        vm.prank(owner);
        lock.setFeeBps(100); // 1%, snapshotted
        uint256 id = _createAndDeliver(arbiter, BOND);
        vm.prank(client);
        lock.dispute(id);
        uint256 toProvider = 400e6;
        uint256 fee = (toProvider * 100) / 10_000;
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeTo);
        vm.prank(arbiter);
        lock.resolve(id, toProvider, false);
        assertEq(usdc.balanceOf(provider), providerBefore + (toProvider - fee) + BOND);
        assertEq(usdc.balanceOf(client), clientBefore + (AMOUNT - toProvider));
        assertEq(usdc.balanceOf(feeTo), feeBefore + fee);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);
    }

    function test_dispute_revertsWithoutArbiter() public {
        uint256 id = _createAndDeliver(address(0), 0);
        vm.prank(client);
        vm.expectRevert(Prooflock.NoArbiter.selector);
        lock.dispute(id);
    }

    function test_dispute_revertsAfterReviewWindow() public {
        uint256 id = _createAndDeliver(arbiter, 0);
        vm.warp(lock.jobs(id).reviewDeadline);
        vm.prank(client);
        vm.expectRevert(Prooflock.ReviewWindowClosed.selector);
        lock.dispute(id);
    }

    function test_dispute_revertsNotClient() public {
        uint256 id = _createAndDeliver(arbiter, 0);
        vm.prank(stranger);
        vm.expectRevert(Prooflock.NotClient.selector);
        lock.dispute(id);
    }

    function test_resolve_revertsNotArbiter() public {
        uint256 id = _createAndDeliver(arbiter, 0);
        vm.prank(client);
        lock.dispute(id);
        vm.prank(stranger);
        vm.expectRevert(Prooflock.NotArbiter.selector);
        lock.resolve(id, 0, false);
    }

    function test_resolve_revertsInvalidSplit() public {
        uint256 id = _createAndDeliver(arbiter, 0);
        vm.prank(client);
        lock.dispute(id);
        vm.prank(arbiter);
        vm.expectRevert(Prooflock.InvalidSplit.selector);
        lock.resolve(id, AMOUNT + 1, false);
    }

    function test_resolve_revertsDouble() public {
        uint256 id = _createAndDeliver(arbiter, 0);
        vm.prank(client);
        lock.dispute(id);
        vm.prank(arbiter);
        lock.resolve(id, AMOUNT / 2, false);
        vm.prank(arbiter);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolve(id, 0, false);
    }

    // ── fees + owner ─────────────────────────────────────────────────────────

    function test_setFee_ownerOnlyAndCap() public {
        vm.prank(stranger);
        vm.expectRevert();
        lock.setFeeBps(100);
        vm.prank(owner);
        vm.expectRevert(Prooflock.FeeTooHigh.selector);
        lock.setFeeBps(501);
        vm.prank(owner);
        lock.setFeeBps(500);
        assertEq(lock.feeBps(), 500);
        vm.prank(owner);
        lock.setFeeBps(0);
        assertEq(lock.feeBps(), 0);
    }

    function test_setFeeRecipient_ownerOnly() public {
        address next_ = makeAddr("nextFee");
        vm.prank(stranger);
        vm.expectRevert();
        lock.setFeeRecipient(next_);
        vm.prank(owner);
        vm.expectRevert(Prooflock.ZeroAddress.selector);
        lock.setFeeRecipient(address(0));
        vm.prank(owner);
        lock.setFeeRecipient(next_);
        assertEq(lock.feeRecipient(), next_);
    }

    function test_feeSnapshot_ignoresLaterFeeChange() public {
        uint256 id = _createAndDeliver(address(0), 0);
        vm.prank(owner);
        lock.setFeeBps(500);
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(client);
        lock.accept(id);
        assertEq(usdc.balanceOf(provider), providerBefore + AMOUNT);
        assertEq(usdc.balanceOf(feeTo), 0);
    }

    // ── double release / conservation ────────────────────────────────────────

    function test_doubleRelease_allTerminalPaths() public {
        uint256 a = _createAndDeliver(address(0), 0);
        vm.prank(client);
        lock.accept(a);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.autoRelease(a);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.refund(a);

        uint256 b = _create(address(0), 0);
        vm.warp(lock.jobs(b).deadline);
        lock.refund(b);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.accept(b);

        // new timeline for a third job
        vm.warp(block.timestamp + 1 hours);
        uint256 c = _createAndDeliver(arbiter, 0);
        vm.prank(client);
        lock.dispute(c);
        vm.prank(arbiter);
        lock.resolve(c, AMOUNT, false);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.accept(c);
        assertEq(lock.totalLocked(), 0);
        assertEq(usdc.balanceOf(address(lock)), 0);
    }

    function testFuzz_splitConserves(uint256 payout, bool slash, uint16 fee) public {
        fee = uint16(bound(fee, 0, 500));
        vm.prank(owner);
        lock.setFeeBps(fee);
        uint256 id = _createAndDeliver(arbiter, BOND);
        payout = bound(payout, 0, AMOUNT);
        vm.prank(client);
        lock.dispute(id);
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeTo);
        vm.prank(arbiter);
        lock.resolve(id, payout, slash);
        uint256 feeAmt = (payout * uint256(fee)) / 10_000;
        uint256 bondToClient = slash ? BOND : 0;
        uint256 bondToProvider = slash ? 0 : BOND;
        assertEq(usdc.balanceOf(provider), providerBefore + (payout - feeAmt) + bondToProvider);
        assertEq(usdc.balanceOf(client), clientBefore + (AMOUNT - payout) + bondToClient);
        assertEq(usdc.balanceOf(feeTo), feeBefore + feeAmt);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);
        assertEq(
            (usdc.balanceOf(provider) - providerBefore) + (usdc.balanceOf(client) - clientBefore)
                + (usdc.balanceOf(feeTo) - feeBefore),
            AMOUNT + BOND
        );
    }

    function testFuzz_createAmounts(uint256 amount, uint256 bond, uint64 lead, uint64 review) public {
        amount = bound(amount, 1, 5_000e6);
        bond = bound(bond, 0, 1_000e6);
        lead = uint64(bound(lead, 1 hours, 180 days));
        review = uint64(bound(review, 1 hours, 30 days));
        Prooflock.JobParams memory p = _params(arbiter, bond);
        p.amount = amount;
        p.deadline = uint64(block.timestamp + lead);
        p.reviewWindow = review;
        vm.prank(client);
        uint256 id = lock.createJob(p);
        assertEq(lock.jobs(id).amount, amount);
        assertEq(usdc.balanceOf(address(lock)), amount);
        assertEq(lock.totalLocked(), amount);
    }
}

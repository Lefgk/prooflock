// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Prooflock} from "../../src/Prooflock.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// USDT-style token: 6 decimals, transfer/transferFrom/approve return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// USDC-like token with a blacklist and a re-entrancy hook fired on every transfer.
contract HookToken is MockUSDC {
    mapping(address => bool) public blacklisted;
    address public target;
    bytes public payload;
    address public hookCaller;
    bool public lastReenterReverted;
    uint256 public hookHits;

    function setBlacklist(address a, bool b) external {
        blacklisted[a] = b;
    }

    function arm(address t, address caller_, bytes calldata data) external {
        target = t;
        hookCaller = caller_;
        payload = data;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, v);
        if (target != address(0) && from != address(0)) {
            hookHits++;
            vm_prank_and_call();
        }
    }

    function vm_prank_and_call() internal {
        // Re-enter as the token itself (msg.sender = token); nonReentrant must reject before any auth check.
        (bool ok,) = target.call(payload);
        lastReenterReverted = !ok;
    }
}

contract ProoflockPolish is Test {
    Prooflock lock;
    MockUSDC usdc;
    address owner = makeAddr("owner");
    address feeTo = makeAddr("feeTo");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address arbiter = makeAddr("arbiter");
    address stranger = makeAddr("stranger");
    bytes32 constant H = keccak256("out");

    function setUp() public {
        usdc = new MockUSDC();
        lock = new Prooflock(address(usdc), owner, feeTo);
        usdc.mint(client, 1_000_000e6);
        usdc.mint(provider, 1_000_000e6);
        vm.prank(client);
        usdc.approve(address(lock), type(uint256).max);
        vm.prank(provider);
        usdc.approve(address(lock), type(uint256).max);
    }

    function _p(address arb, uint256 amount, uint256 bond) internal view returns (Prooflock.JobParams memory p) {
        p.provider = provider;
        p.arbiter = arb;
        p.amount = amount;
        p.deadline = uint64(block.timestamp + 7 days);
        p.reviewWindow = 3 days;
        p.bondRequired = bond;
    }

    function _create(Prooflock l, address arb, uint256 amount, uint256 bond) internal returns (uint256 id) {
        vm.prank(client);
        id = l.createJob(_p(arb, amount, bond));
    }

    function _deliver(Prooflock l, uint256 id, bool bond) internal {
        if (bond) {
            vm.prank(provider);
            l.postBond(id);
        }
        vm.prank(provider);
        l.deliver(id, H, "u");
    }

    // ── Time boundaries ──────────────────────────────────────────────────────

    function test_deadline_exactBoundary() public {
        uint256 id = _create(lock, address(0), 100e6, 0);
        uint64 dl = lock.jobs(id).deadline;
        vm.warp(dl - 1);
        vm.prank(provider);
        lock.deliver(id, H, "");
        // second job: at deadline deliver is closed and refund is open
        uint256 id2 = _create(lock, address(0), 100e6, 0);
        uint64 dl2 = lock.jobs(id2).deadline;
        vm.warp(dl2);
        vm.prank(provider);
        vm.expectRevert(Prooflock.DeadlinePassed.selector);
        lock.deliver(id2, H, "");
        vm.expectRevert(Prooflock.BondNotRequired.selector);
        vm.prank(provider);
        lock.postBond(id2);
        lock.refund(id2);
        assertEq(uint8(lock.jobs(id2).status), uint8(Prooflock.Status.Refunded));
    }

    function test_reviewDeadline_exactBoundary() public {
        uint256 id = _create(lock, arbiter, 100e6, 0);
        _deliver(lock, id, false);
        uint64 rd = lock.jobs(id).reviewDeadline;
        vm.warp(rd - 1);
        vm.expectRevert(Prooflock.ReviewWindowOpen.selector);
        lock.autoRelease(id);
        vm.warp(rd);
        // dispute closed exactly at reviewDeadline, autoRelease open
        vm.prank(client);
        vm.expectRevert(Prooflock.ReviewWindowClosed.selector);
        lock.dispute(id);
        lock.autoRelease(id);
        assertEq(usdc.balanceOf(address(lock)), 0);
    }

    function test_dispute_atLastSecondBeforeReviewDeadline() public {
        uint256 id = _create(lock, arbiter, 100e6, 0);
        _deliver(lock, id, false);
        vm.warp(lock.jobs(id).reviewDeadline - 1);
        vm.prank(client);
        lock.dispute(id);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.autoRelease(id);
    }

    function test_createJob_deadlineBounds() public {
        Prooflock.JobParams memory p = _p(address(0), 1e6, 0);
        p.deadline = uint64(block.timestamp + 1 hours);
        vm.prank(client);
        lock.createJob(p); // exactly MIN lead ok
        p.deadline = uint64(block.timestamp + 180 days);
        vm.prank(client);
        lock.createJob(p); // exactly MAX ok
        p.deadline = uint64(block.timestamp + 180 days + 1);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidDeadline.selector);
        lock.createJob(p);
        p.deadline = uint64(block.timestamp + 1 hours - 1);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidDeadline.selector);
        lock.createJob(p);
        p.deadline = uint64(block.timestamp + 7 days);
        p.reviewWindow = 1 hours;
        vm.prank(client);
        lock.createJob(p);
        p.reviewWindow = 30 days;
        vm.prank(client);
        lock.createJob(p);
        p.reviewWindow = 30 days + 1;
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidReviewWindow.selector);
        lock.createJob(p);
    }

    // ── Status gating / wrong caller ─────────────────────────────────────────

    function test_statusGating() public {
        uint256 id = _create(lock, arbiter, 100e6, 10e6);
        // unknown / None job
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.accept(999);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.refund(999);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolveStaleDispute(999);
        // Funded: can't accept/dispute/resolve/autoRelease
        vm.startPrank(client);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.accept(id);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.dispute(id);
        vm.stopPrank();
        vm.prank(arbiter);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolve(id, 0, false);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.autoRelease(id);
        // Delivered: can't postBond/deliver again/refund
        _deliver(lock, id, true);
        vm.prank(provider);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.postBond(id);
        vm.prank(provider);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.deliver(id, H, "");
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.refund(id);
    }

    function test_wrongCallers() public {
        uint256 id = _create(lock, arbiter, 100e6, 0);
        _deliver(lock, id, false);
        vm.prank(provider);
        vm.expectRevert(Prooflock.NotClient.selector);
        lock.accept(id);
        vm.prank(arbiter);
        vm.expectRevert(Prooflock.NotClient.selector);
        lock.dispute(id);
        vm.prank(client);
        lock.dispute(id);
        // client / provider / stranger can't resolve
        address[3] memory bad = [client, provider, stranger];
        for (uint256 i; i < 3; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(Prooflock.NotArbiter.selector);
            lock.resolve(id, 50e6, false);
        }
    }

    function test_resolve_extremes() public {
        // provider gets 0 with slash, with fee: no fee on 0, client gets all + bond
        vm.prank(owner);
        lock.setFeeBps(500);
        uint256 id = _create(lock, arbiter, 100e6, 20e6);
        _deliver(lock, id, true);
        vm.prank(client);
        lock.dispute(id);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(arbiter);
        lock.resolve(id, 0, true);
        assertEq(usdc.balanceOf(client) - c0, 120e6);
        assertEq(usdc.balanceOf(feeTo), 0);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);

        // full payout, fee 5%, bond back
        uint256 id2 = _create(lock, arbiter, 100e6, 20e6);
        _deliver(lock, id2, true);
        vm.prank(client);
        lock.dispute(id2);
        uint256 p0 = usdc.balanceOf(provider);
        vm.prank(arbiter);
        lock.resolve(id2, 100e6, false);
        assertEq(usdc.balanceOf(provider) - p0, 95e6 + 20e6);
        assertEq(usdc.balanceOf(feeTo), 5e6);
        assertEq(lock.totalLocked(), 0);
    }

    function test_resolve_events() public {
        vm.prank(owner);
        lock.setFeeBps(100);
        uint256 id = _create(lock, arbiter, 1_000e6, 0);
        _deliver(lock, id, false);
        vm.prank(client);
        lock.dispute(id);
        vm.expectEmit(true, false, false, true, address(lock));
        emit Prooflock.Resolved(id, 400e6 - 4e6, 600e6, 4e6, false);
        vm.prank(arbiter);
        lock.resolve(id, 400e6, false);
    }

    function test_resolveStale_arbiterCannotResolveAfterSettle() public {
        uint256 id = _create(lock, arbiter, 101, 0);
        _deliver(lock, id, false);
        vm.prank(client);
        lock.dispute(id);
        vm.warp(lock.jobs(id).reviewDeadline + lock.DISPUTE_TIMEOUT());
        uint256 c0 = usdc.balanceOf(client);
        lock.resolveStaleDispute(id);
        assertEq(usdc.balanceOf(client) - c0, 51); // odd unit to client
        vm.prank(arbiter);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolve(id, 0, true);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolveStaleDispute(id);
    }

    // ── Fee rounding ─────────────────────────────────────────────────────────

    function test_fee_roundsDownTinyAmounts() public {
        vm.prank(owner);
        lock.setFeeBps(500);
        uint256 id = _create(lock, address(0), 19, 0); // 19*5% = 0.95 -> 0 fee
        _deliver(lock, id, false);
        vm.prank(client);
        lock.accept(id);
        assertEq(usdc.balanceOf(feeTo), 0);
        uint256 id2 = _create(lock, address(0), 20, 0);
        _deliver(lock, id2, false);
        vm.prank(client);
        lock.accept(id2);
        assertEq(usdc.balanceOf(feeTo), 1);
        assertEq(lock.totalLocked(), 0);
    }

    function test_feeSnapshot_zeroFeeJobStaysZeroAfterRaise() public {
        uint256 id = _create(lock, address(0), 100e6, 0);
        vm.prank(owner);
        lock.setFeeBps(500);
        _deliver(lock, id, false);
        vm.prank(client);
        lock.accept(id);
        assertEq(usdc.balanceOf(feeTo), 0);
        assertEq(lock.jobs(id).feeBps, 0);
    }

    function test_feeRecipientChange_appliesToExistingJobs() public {
        vm.prank(owner);
        lock.setFeeBps(100);
        uint256 id = _create(lock, address(0), 100e6, 0);
        address newTo = makeAddr("newTo");
        vm.prank(owner);
        lock.setFeeRecipient(newTo);
        _deliver(lock, id, false);
        vm.prank(client);
        lock.accept(id);
        assertEq(usdc.balanceOf(newTo), 1e6);
        assertEq(usdc.balanceOf(feeTo), 0);
    }

    // ── Ownership ────────────────────────────────────────────────────────────

    function test_ownable2Step() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(stranger);
        vm.expectRevert();
        lock.transferOwnership(newOwner);
        vm.prank(owner);
        lock.transferOwnership(newOwner);
        assertEq(lock.owner(), owner); // not yet
        vm.prank(stranger);
        vm.expectRevert();
        lock.acceptOwnership();
        vm.prank(newOwner);
        lock.acceptOwnership();
        assertEq(lock.owner(), newOwner);
        vm.prank(owner);
        vm.expectRevert();
        lock.setFeeBps(1);
        vm.prank(newOwner);
        lock.setFeeBps(1);
    }

    function test_ownerCannotTouchEscrowedFunds() public {
        uint256 id = _create(lock, address(0), 100e6, 0);
        // owner has no privileged path: every settlement fn is status/caller-gated
        vm.startPrank(owner);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.accept(id);
        vm.expectRevert(Prooflock.DeadlineNotReached.selector);
        lock.refund(id);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(lock)), 100e6);
    }

    function test_setters_emitEvents() public {
        vm.expectEmit(false, false, false, true, address(lock));
        emit Prooflock.FeeUpdated(123);
        vm.prank(owner);
        lock.setFeeBps(123);
        address r = makeAddr("r");
        vm.expectEmit(true, false, false, false, address(lock));
        emit Prooflock.FeeRecipientUpdated(r);
        vm.prank(owner);
        lock.setFeeRecipient(r);
        vm.prank(owner);
        vm.expectRevert(Prooflock.ZeroAddress.selector);
        lock.setFeeRecipient(address(0));
    }

    // ── Views / indexing ─────────────────────────────────────────────────────

    function test_jobsOf_andIds() public {
        uint256 a = _create(lock, address(0), 1e6, 0);
        uint256 b = _create(lock, address(0), 1e6, 0);
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(lock.nextJobId(), 3);
        uint256[] memory cj = lock.jobsOf(client);
        uint256[] memory pj = lock.jobsOf(provider);
        assertEq(cj.length, 2);
        assertEq(pj.length, 2);
        assertEq(lock.jobsOf(stranger).length, 0);
        assertTrue(lock.isTerminal(Prooflock.Status.Released));
        assertTrue(lock.isTerminal(Prooflock.Status.Refunded));
        assertTrue(lock.isTerminal(Prooflock.Status.Resolved));
        assertFalse(lock.isTerminal(Prooflock.Status.Disputed));
        assertFalse(lock.isTerminal(Prooflock.Status.None));
    }

    function test_createJob_insufficientAllowanceOrBalanceReverts() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        lock.createJob(_p(address(0), 1e6, 0));
        usdc.mint(poor, 1e6);
        vm.prank(poor);
        vm.expectRevert(); // no allowance
        lock.createJob(_p(address(0), 1e6, 0));
        assertEq(lock.nextJobId(), 1); // state rolled back
    }

    function test_createJob_maxAmountReverts() public {
        vm.prank(client);
        vm.expectRevert();
        lock.createJob(_p(address(0), type(uint256).max, 0));
    }

    function test_postBond_zeroBondRequiredAndHugeBondRequired() public {
        // huge bond: job can be created but provider can never deliver; client refunds after deadline
        uint256 id = _create(lock, address(0), 10e6, type(uint256).max);
        vm.prank(provider);
        vm.expectRevert();
        lock.postBond(id);
        vm.prank(provider);
        vm.expectRevert(Prooflock.BondNotPosted.selector);
        lock.deliver(id, H, "");
        vm.warp(block.timestamp + 7 days);
        uint256 c0 = usdc.balanceOf(client);
        lock.refund(id);
        assertEq(usdc.balanceOf(client) - c0, 10e6);
        assertEq(lock.totalLocked(), 0);
    }

    // ── Non-standard token (USDT-style, no return value) ─────────────────────

    function test_noReturnToken_fullLifecycle() public {
        NoReturnToken t = new NoReturnToken();
        Prooflock l = new Prooflock(address(t), owner, feeTo);
        t.mint(client, 1_000e6);
        t.mint(provider, 1_000e6);
        vm.prank(client);
        t.approve(address(l), type(uint256).max);
        vm.prank(provider);
        t.approve(address(l), type(uint256).max);
        vm.prank(owner);
        l.setFeeBps(200);

        uint256 id = _create(l, arbiter, 500e6, 50e6);
        _deliver(l, id, true);
        vm.prank(client);
        l.accept(id);
        assertEq(t.balanceOf(feeTo), 10e6);
        assertEq(t.balanceOf(provider), 1_000e6 + 500e6 - 10e6);
        assertEq(t.balanceOf(address(l)), 0);

        uint256 id2 = _create(l, address(0), 100e6, 0);
        vm.warp(block.timestamp + 8 days);
        l.refund(id2);
        assertEq(t.balanceOf(address(l)), 0);
    }

    // ── Reentrancy via token hook ────────────────────────────────────────────

    function _hookSetup() internal returns (HookToken t, Prooflock l) {
        t = new HookToken();
        l = new Prooflock(address(t), owner, feeTo);
        t.mint(client, 1_000e6);
        t.mint(provider, 1_000e6);
        vm.prank(client);
        t.approve(address(l), type(uint256).max);
        vm.prank(provider);
        t.approve(address(l), type(uint256).max);
    }

    function test_reentrancy_blockedOnCreateAndSettle() public {
        (HookToken t, Prooflock l) = _hookSetup();
        // hook tries to re-enter createJob during transferFrom
        t.arm(address(l), address(0), abi.encodeCall(Prooflock.createJob, (_p(address(0), 1e6, 0))));
        uint256 id = _create(l, address(0), 100e6, 0);
        assertEq(t.hookHits(), 1);
        assertTrue(t.lastReenterReverted());
        assertEq(l.nextJobId(), 2);

        _deliver(l, id, false);
        // hook tries to re-enter accept / refund / autoRelease during payout
        t.arm(address(l), address(0), abi.encodeCall(Prooflock.autoRelease, (id)));
        vm.prank(client);
        l.accept(id);
        assertTrue(t.lastReenterReverted());
        assertGe(t.hookHits(), 2);
        assertEq(t.balanceOf(address(l)), 0);
        assertEq(l.totalLocked(), 0);
        assertEq(t.balanceOf(provider), 1_000e6 + 100e6);
    }

    // ── Blacklist (documents acknowledged L-1) ───────────────────────────────

    function test_L1_blacklistedProviderBlocksRefundUntilCleared() public {
        (HookToken t, Prooflock l) = _hookSetup();
        uint256 id = _create(l, address(0), 100e6, 10e6);
        vm.prank(provider);
        l.postBond(id);
        t.setBlacklist(provider, true);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(bytes("blacklisted"));
        l.refund(id); // acknowledged L-1: pull payments not implemented
        t.setBlacklist(provider, false);
        l.refund(id);
        assertEq(t.balanceOf(address(l)), 0);
    }

    function test_L2_blacklistedFeeRecipientOnlyBlocksFeeBearingJobs() public {
        (HookToken t, Prooflock l) = _hookSetup();
        uint256 zeroFee = _create(l, address(0), 100e6, 0);
        vm.prank(owner);
        l.setFeeBps(100);
        uint256 withFee = _create(l, address(0), 100e6, 0);
        _deliver(l, zeroFee, false);
        _deliver(l, withFee, false);
        t.setBlacklist(feeTo, true);
        vm.prank(client);
        l.accept(zeroFee); // snapshotted 0 fee unaffected
        vm.prank(client);
        vm.expectRevert(bytes("blacklisted"));
        l.accept(withFee);
        vm.prank(owner);
        l.setFeeRecipient(makeAddr("clean")); // owner can rescue
        vm.prank(client);
        l.accept(withFee);
        assertEq(l.totalLocked(), 0);
    }

    // ── Production-scale amounts (6-decimal USDC) ────────────────────────────

    function test_productionScale_largeEscrowWithFee() public {
        uint256 big = 1_000_000_000e6; // 1B USDC
        usdc.mint(client, big);
        vm.prank(owner);
        lock.setFeeBps(500);
        uint256 id = _create(lock, address(0), big, 0);
        _deliver(lock, id, false);
        vm.prank(client);
        lock.accept(id);
        assertEq(usdc.balanceOf(feeTo), big / 20);
        assertEq(usdc.balanceOf(address(lock)), 0);
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_acceptConservation(uint256 amount, uint256 bond, uint16 fee) public {
        amount = bound(amount, 1, 100_000e6);
        bond = bound(bond, 0, 100_000e6);
        fee = uint16(bound(fee, 0, 500));
        vm.prank(owner);
        lock.setFeeBps(fee);
        uint256 total0 = usdc.balanceOf(client) + usdc.balanceOf(provider) + usdc.balanceOf(feeTo);
        uint256 id = _create(lock, arbiter, amount, bond);
        _deliver(lock, id, bond > 0);
        assertEq(lock.totalLocked(), amount + bond);
        vm.prank(client);
        lock.accept(id);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);
        assertEq(usdc.balanceOf(client) + usdc.balanceOf(provider) + usdc.balanceOf(feeTo), total0);
        assertEq(usdc.balanceOf(feeTo), (amount * fee) / 10_000);
    }

    function testFuzz_refundConservation(uint256 amount, uint256 bond, uint256 lateBy) public {
        amount = bound(amount, 1, 100_000e6);
        bond = bound(bond, 0, 100_000e6);
        lateBy = bound(lateBy, 0, 365 days);
        uint256 c0 = usdc.balanceOf(client);
        uint256 p0 = usdc.balanceOf(provider);
        uint256 id = _create(lock, address(0), amount, bond);
        if (bond > 0) {
            vm.prank(provider);
            lock.postBond(id);
        }
        vm.warp(lock.jobs(id).deadline + lateBy);
        vm.prank(stranger);
        lock.refund(id);
        assertEq(usdc.balanceOf(client), c0);
        assertEq(usdc.balanceOf(provider), p0);
        assertEq(usdc.balanceOf(address(lock)), 0);
    }

    function testFuzz_wrongCallerNeverMovesFunds(address who, uint256 payout) public {
        vm.assume(who != client && who != arbiter && who != provider && who != address(lock));
        uint256 id = _create(lock, arbiter, 100e6, 0);
        _deliver(lock, id, false);
        vm.startPrank(who);
        vm.expectRevert(Prooflock.NotClient.selector);
        lock.accept(id);
        vm.expectRevert(Prooflock.NotClient.selector);
        lock.dispute(id);
        vm.stopPrank();
        vm.prank(client);
        lock.dispute(id);
        vm.prank(who);
        vm.expectRevert(Prooflock.NotArbiter.selector);
        lock.resolve(id, payout, true);
        assertEq(usdc.balanceOf(address(lock)), 100e6);
    }

    function testFuzz_resolveOverAmountReverts(uint256 payout) public {
        payout = bound(payout, 100e6 + 1, type(uint256).max);
        uint256 id = _create(lock, arbiter, 100e6, 0);
        _deliver(lock, id, false);
        vm.prank(client);
        lock.dispute(id);
        vm.prank(arbiter);
        vm.expectRevert(Prooflock.InvalidSplit.selector);
        lock.resolve(id, payout, false);
    }

    function testFuzz_resolveConservation(uint256 amount, uint256 payout, bool slash, uint16 fee, bool withBond)
        public
    {
        amount = bound(amount, 1, 100_000e6);
        payout = bound(payout, 0, amount);
        fee = uint16(bound(fee, 0, 500));
        uint256 bond = withBond ? 7e6 : 0;
        vm.prank(owner);
        lock.setFeeBps(fee);
        uint256 total0 = usdc.balanceOf(client) + usdc.balanceOf(provider) + usdc.balanceOf(feeTo);
        uint256 id = _create(lock, arbiter, amount, bond);
        _deliver(lock, id, withBond);
        vm.prank(client);
        lock.dispute(id);
        vm.prank(arbiter);
        lock.resolve(id, payout, slash);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);
        assertEq(usdc.balanceOf(client) + usdc.balanceOf(provider) + usdc.balanceOf(feeTo), total0);
        assertEq(usdc.balanceOf(feeTo), (payout * fee) / 10_000);
    }
}

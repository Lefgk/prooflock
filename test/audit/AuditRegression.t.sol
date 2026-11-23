// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Prooflock} from "../../src/Prooflock.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// Audit 2026-11-23 regression tests. The M-1 test started as a PoC that PASSED on main
/// (funds still locked after 10 years) and now asserts the stale dispute can be settled.
contract ProoflockAuditRegression is Test {
    Prooflock lock;
    MockUSDC usdc;
    address owner = makeAddr("owner");
    address feeTo = makeAddr("feeTo");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address arbiter = makeAddr("arbiter");
    address keeper = makeAddr("keeper");

    function setUp() public {
        usdc = new MockUSDC();
        lock = new Prooflock(address(usdc), owner, feeTo);
        usdc.mint(client, 10_000e6);
        usdc.mint(provider, 1_000e6);
        vm.prank(client);
        usdc.approve(address(lock), type(uint256).max);
        vm.prank(provider);
        usdc.approve(address(lock), type(uint256).max);
    }

    function _disputed(uint256 amount, uint256 bond) internal returns (uint256 id) {
        Prooflock.JobParams memory p;
        p.provider = provider;
        p.arbiter = arbiter;
        p.amount = amount;
        p.deadline = uint64(block.timestamp + 7 days);
        p.reviewWindow = 3 days;
        p.bondRequired = bond;
        vm.prank(client);
        id = lock.createJob(p);
        if (bond > 0) {
            vm.prank(provider);
            lock.postBond(id);
        }
        vm.prank(provider);
        lock.deliver(id, keccak256("x"), "");
        vm.prank(client);
        lock.dispute(id);
    }

    function test_M1_silentArbiterNoLongerLocksFunds() public {
        uint256 id = _disputed(1_000e6, 100e6);
        uint64 rd = lock.jobs(id).reviewDeadline;
        vm.warp(uint256(rd) + lock.DISPUTE_TIMEOUT() - 1);
        vm.prank(keeper);
        vm.expectRevert(Prooflock.DisputeNotExpired.selector);
        lock.resolveStaleDispute(id);
        vm.warp(uint256(rd) + lock.DISPUTE_TIMEOUT());
        uint256 c0 = usdc.balanceOf(client);
        uint256 p0 = usdc.balanceOf(provider);
        vm.prank(keeper);
        lock.resolveStaleDispute(id);
        assertEq(usdc.balanceOf(client) - c0, 500e6);
        assertEq(usdc.balanceOf(provider) - p0, 600e6, "half + bond back");
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);
        assertEq(uint8(lock.jobs(id).status), uint8(Prooflock.Status.Resolved));
        // cannot be settled twice, arbiter can no longer resolve
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolveStaleDispute(id);
        vm.prank(arbiter);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolve(id, 0, true);
    }

    function test_M1_arbiterStillResolvesBeforeOrAfterTimeoutUntilSettled() public {
        uint256 id = _disputed(1_000e6, 0);
        vm.warp(block.timestamp + 365 days);
        vm.prank(arbiter);
        lock.resolve(id, 0, false);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolveStaleDispute(id);
    }

    function test_M1_staleOnlyForDisputed() public {
        Prooflock.JobParams memory p;
        p.provider = provider;
        p.arbiter = arbiter;
        p.amount = 1e6;
        p.deadline = uint64(block.timestamp + 7 days);
        p.reviewWindow = 3 days;
        vm.prank(client);
        uint256 id = lock.createJob(p);
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.resolveStaleDispute(id);
    }

    function testFuzz_M1_staleSplitConserves(uint256 amount, uint16 fee, bool withBond) public {
        amount = bound(amount, 1, 5_000e6);
        fee = uint16(bound(fee, 0, lock.MAX_FEE_BPS()));
        vm.prank(owner);
        lock.setFeeBps(fee);
        uint256 bond = withBond ? 50e6 : 0;
        uint256 id = _disputed(amount, bond);
        vm.warp(uint256(lock.jobs(id).reviewDeadline) + lock.DISPUTE_TIMEOUT());
        uint256 c0 = usdc.balanceOf(client);
        uint256 p0 = usdc.balanceOf(provider);
        lock.resolveStaleDispute(id);
        uint256 half = amount / 2;
        uint256 f = (half * fee) / 10_000;
        assertEq(usdc.balanceOf(client) - c0, amount - half);
        assertEq(usdc.balanceOf(provider) - p0, half - f + bond);
        assertEq(usdc.balanceOf(feeTo), f);
        assertEq(usdc.balanceOf(address(lock)), 0);
    }
}

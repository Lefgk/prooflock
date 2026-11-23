// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Prooflock} from "../src/Prooflock.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract ProoflockHandler is Test {
    Prooflock public lock;
    MockUSDC public usdc;
    address public client;
    address public provider;
    address public arbiter;
    address public feeTo;

    uint256 public settledOut; // total USDC paid out of the contract by settlements
    uint256 public ghostFunded; // amount + bond ever locked
    uint256 public calls;

    constructor(Prooflock lock_, MockUSDC usdc_, address client_, address provider_, address arbiter_, address feeTo_) {
        lock = lock_;
        usdc = usdc_;
        client = client_;
        provider = provider_;
        arbiter = arbiter_;
        feeTo = feeTo_;
    }

    function createJob(uint256 amount, uint256 bond, uint64 lead, uint64 review, bool withArbiter) external {
        amount = bound(amount, 1e6, 2_000e6);
        bond = bound(bond, 0, 200e6);
        lead = uint64(bound(lead, 1 hours, 30 days));
        review = uint64(bound(review, 1 hours, 14 days));
        if (usdc.balanceOf(client) < amount) return;
        Prooflock.JobParams memory p = Prooflock.JobParams({
            provider: provider,
            arbiter: withArbiter ? arbiter : address(0),
            amount: amount,
            deadline: uint64(block.timestamp + lead),
            reviewWindow: review,
            bondRequired: bond,
            clientAgentId: 0,
            providerAgentId: 0,
            metadataURI: ""
        });
        vm.prank(client);
        try lock.createJob(p) {
            ghostFunded += amount;
            calls++;
        } catch {}
    }

    function postBond(uint256 idHint) external {
        uint256 id = _id(idHint);
        if (id == 0) return;
        Prooflock.Job memory job = lock.jobs(id);
        if (job.status != Prooflock.Status.Funded || job.bondRequired == 0 || job.bondDeposited != 0) return;
        if (usdc.balanceOf(provider) < job.bondRequired) return;
        vm.prank(provider);
        try lock.postBond(id) {
            ghostFunded += job.bondRequired;
            calls++;
        } catch {}
    }

    function deliver(uint256 idHint) external {
        uint256 id = _id(idHint);
        if (id == 0) return;
        vm.prank(provider);
        try lock.deliver(id, keccak256(abi.encode(id)), "") {
            calls++;
        } catch {}
    }

    function accept(uint256 idHint) external {
        uint256 id = _id(idHint);
        if (id == 0) return;
        uint256 before = usdc.balanceOf(address(lock));
        vm.prank(client);
        try lock.accept(id) {
            settledOut += before - usdc.balanceOf(address(lock));
            calls++;
        } catch {}
    }

    function autoRelease(uint256 idHint) external {
        uint256 id = _id(idHint);
        if (id == 0) return;
        uint256 before = usdc.balanceOf(address(lock));
        try lock.autoRelease(id) {
            settledOut += before - usdc.balanceOf(address(lock));
            calls++;
        } catch {}
    }

    function refund(uint256 idHint) external {
        uint256 id = _id(idHint);
        if (id == 0) return;
        uint256 before = usdc.balanceOf(address(lock));
        try lock.refund(id) {
            settledOut += before - usdc.balanceOf(address(lock));
            calls++;
        } catch {}
    }

    function dispute(uint256 idHint) external {
        uint256 id = _id(idHint);
        if (id == 0) return;
        vm.prank(client);
        try lock.dispute(id) {
            calls++;
        } catch {}
    }

    function resolve(uint256 idHint, uint256 payout, bool slash) external {
        uint256 id = _id(idHint);
        if (id == 0) return;
        Prooflock.Job memory job = lock.jobs(id);
        if (job.amount > 0) payout = bound(payout, 0, job.amount);
        uint256 before = usdc.balanceOf(address(lock));
        vm.prank(arbiter);
        try lock.resolve(id, payout, slash) {
            settledOut += before - usdc.balanceOf(address(lock));
            calls++;
        } catch {}
    }

    bool public ghostStaleStuck;

    /// Audit M-1: a dispute past reviewDeadline + DISPUTE_TIMEOUT must always be settleable by anyone.
    function resolveStale(uint256 idHint) external {
        uint256 id = _id(idHint);
        if (id == 0) return;
        Prooflock.Job memory job = lock.jobs(id);
        if (job.status != Prooflock.Status.Disputed) return;
        uint256 due = uint256(job.reviewDeadline) + lock.DISPUTE_TIMEOUT();
        if (block.timestamp < due) {
            vm.expectRevert(Prooflock.DisputeNotExpired.selector);
            lock.resolveStaleDispute(id);
            vm.warp(due);
        }
        uint256 before = usdc.balanceOf(address(lock));
        try lock.resolveStaleDispute(id) {
            settledOut += before - usdc.balanceOf(address(lock));
            calls++;
        } catch {
            ghostStaleStuck = true;
        }
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 40 days));
    }

    function _id(uint256 hint) internal view returns (uint256) {
        uint256 n = lock.nextJobId();
        if (n <= 1) return 0;
        return bound(hint, 1, n - 1);
    }
}

contract ProoflockInvariantTest is StdInvariant, Test {
    Prooflock internal lock;
    MockUSDC internal usdc;
    ProoflockHandler internal handler;
    address internal owner = makeAddr("inv-owner");
    address internal feeTo = makeAddr("inv-fee");
    address internal client = makeAddr("inv-client");
    address internal provider = makeAddr("inv-provider");
    address internal arbiter = makeAddr("inv-arbiter");

    function setUp() public {
        usdc = new MockUSDC();
        lock = new Prooflock(address(usdc), owner, feeTo);
        usdc.mint(client, 1_000_000e6);
        usdc.mint(provider, 1_000_000e6);
        vm.prank(client);
        usdc.approve(address(lock), type(uint256).max);
        vm.prank(provider);
        usdc.approve(address(lock), type(uint256).max);
        handler = new ProoflockHandler(lock, usdc, client, provider, arbiter, feeTo);
        targetContract(address(handler));
    }

    /// @notice Escrow conservation: contract balance equals currently locked amounts + bonds.
    function invariant_balanceEqualsTotalLocked() public view {
        assertEq(usdc.balanceOf(address(lock)), lock.totalLocked());
    }

    /// @notice Sum of open job amounts and bonds matches totalLocked; terminal jobs hold nothing.
    function invariant_openJobsMatchLockedAndTerminalAreZero() public view {
        uint256 sum;
        uint256 n = lock.nextJobId();
        for (uint256 i = 1; i < n; i++) {
            Prooflock.Job memory job = lock.jobs(i);
            if (lock.isTerminal(job.status)) {
                assertEq(job.amount, 0);
                assertEq(job.bondDeposited, 0);
            } else {
                sum += job.amount + job.bondDeposited;
            }
        }
        assertEq(sum, lock.totalLocked());
        assertEq(usdc.balanceOf(address(lock)), sum);
    }

    function invariant_staleDisputeAlwaysSettleable() public view {
        assertFalse(handler.ghostStaleStuck());
    }

    /// @notice Everything that ever entered the escrow is either still locked or has been paid out.
    ///         No double release: payouts plus remaining lock equal funds that entered.
    function invariant_noDoubleRelease() public view {
        assertEq(handler.ghostFunded(), lock.totalLocked() + handler.settledOut());
        assertEq(
            usdc.balanceOf(client) + usdc.balanceOf(provider) + usdc.balanceOf(feeTo) + usdc.balanceOf(address(lock)),
            2_000_000e6
        );
    }
}

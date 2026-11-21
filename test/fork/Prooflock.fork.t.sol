// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Prooflock} from "../../src/Prooflock.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";
import {FundUsdc} from "../FundUsdc.sol";

/// @dev Runs against a fork of a live chain using the chain's real Circle USDC.
///      Either run `forge test --fork-url <rpc>` (only the matching chain's suite runs), or set
///      MAINNET_FORK_RPC / BASE_FORK_RPC (e.g. a local `anvil --fork-url`). Otherwise skipped.
abstract contract ForkBase is Test, FundUsdc {
    Prooflock internal lock;
    IERC20Metadata internal usdc;
    address internal owner = makeAddr("fork-owner");
    address internal feeTo = makeAddr("fork-fee");
    address internal client = makeAddr("fork-client");
    address internal provider = makeAddr("fork-provider");
    address internal arbiter = makeAddr("fork-arbiter");
    bool internal active;

    uint256 internal constant AMOUNT = 1_000e6;
    uint256 internal constant BOND = 50e6;
    bytes32 internal constant HASH = keccak256("fork-deliverable");

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already running on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
        usdc = IERC20Metadata(DeployConfig.get(block.chainid).usdc);
        lock = new Prooflock(address(usdc), owner, feeTo);

        fundUsdc(address(usdc), client, 10_000e6);
        fundUsdc(address(usdc), provider, 10_000e6);
        vm.prank(client);
        IERC20(address(usdc)).approve(address(lock), type(uint256).max);
        vm.prank(provider);
        IERC20(address(usdc)).approve(address(lock), type(uint256).max);
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _params(address arb, uint256 bond) internal view returns (Prooflock.JobParams memory p) {
        p.provider = provider;
        p.arbiter = arb;
        p.amount = AMOUNT;
        p.deadline = uint64(block.timestamp + 7 days);
        p.reviewWindow = 2 days;
        p.bondRequired = bond;
        p.metadataURI = "ipfs://fork";
    }

    function test_fork_realUsdcMetadata() public onFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertGt(address(usdc).code.length, 0);
        assertEq(address(usdc), DeployConfig.get(block.chainid).usdc);
        assertEq(usdc.balanceOf(client), 10_000e6);
    }

    function test_fork_createDeliverAcceptWithRealUsdc() public onFork {
        vm.prank(client);
        uint256 id = lock.createJob(_params(arbiter, BOND));
        assertEq(usdc.balanceOf(address(lock)), AMOUNT);

        vm.prank(provider);
        lock.postBond(id);
        assertEq(usdc.balanceOf(address(lock)), AMOUNT + BOND);

        vm.prank(provider);
        lock.deliver(id, HASH, "ipfs://out");

        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(client);
        lock.accept(id);
        assertEq(uint8(lock.jobs(id).status), uint8(Prooflock.Status.Released));
        assertEq(usdc.balanceOf(provider), providerBefore + AMOUNT + BOND);
        assertEq(usdc.balanceOf(address(lock)), 0);
        assertEq(lock.totalLocked(), 0);
    }

    function test_fork_refundOnMissedDeadline() public onFork {
        vm.prank(client);
        uint256 id = lock.createJob(_params(address(0), BOND));
        vm.prank(provider);
        lock.postBond(id);
        vm.warp(lock.jobs(id).deadline);
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 providerBefore = usdc.balanceOf(provider);
        lock.refund(id);
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT);
        assertEq(usdc.balanceOf(provider), providerBefore + BOND);
        assertEq(lock.totalLocked(), 0);
    }

    function test_fork_arbiterSplit() public onFork {
        vm.prank(owner);
        lock.setFeeBps(100);
        vm.prank(client);
        uint256 id = lock.createJob(_params(arbiter, 0));
        vm.prank(provider);
        lock.deliver(id, HASH, "");
        vm.prank(client);
        lock.dispute(id);
        uint256 payout = 600e6;
        uint256 fee = (payout * 100) / 10_000;
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore = usdc.balanceOf(feeTo);
        vm.prank(arbiter);
        lock.resolve(id, payout, false);
        assertEq(usdc.balanceOf(provider), providerBefore + payout - fee);
        assertEq(usdc.balanceOf(client), clientBefore + (AMOUNT - payout));
        assertEq(usdc.balanceOf(feeTo), feeBefore + fee);
        assertEq(usdc.balanceOf(address(lock)), 0);
    }

    function test_fork_doubleReleaseReverts() public onFork {
        vm.prank(client);
        uint256 id = lock.createJob(_params(address(0), 0));
        vm.prank(provider);
        lock.deliver(id, HASH, "");
        vm.prank(client);
        lock.accept(id);
        vm.prank(client);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.accept(id);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.autoRelease(id);
        vm.expectRevert(Prooflock.InvalidStatus.selector);
        lock.refund(id);
    }
}

contract EthereumForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}

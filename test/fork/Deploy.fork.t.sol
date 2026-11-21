// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Prooflock} from "../../src/Prooflock.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";

/// @dev Runs the production Deploy script against a live-chain fork (no broadcast to a real network).
abstract contract DeployForkBase is Test {
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deployScript_escrowAndCanonicalUsdc() public onFork {
        Deploy script = new Deploy();
        (Prooflock escrow, address usdc) = script.run();

        assertTrue(address(escrow).code.length > 0, "escrow not deployed");
        assertEq(usdc, DeployConfig.get(block.chainid).usdc, "must use canonical USDC");
        assertEq(IERC20Metadata(usdc).symbol(), "USDC");
        assertEq(IERC20Metadata(usdc).decimals(), 6);
        assertEq(address(escrow.usdc()), usdc);
        assertEq(escrow.owner(), address(this));
        assertEq(escrow.feeRecipient(), address(this));
        assertEq(escrow.feeBps(), 0);
        assertEq(escrow.MAX_FEE_BPS(), 500);
    }

    function test_fork_deployScript_confirmMainnetNotSetIsDryRunSafe() public onFork {
        // In a test, ForgeContext is not ScriptBroadcast, so run() must still succeed
        // without CONFIRM_MAINNET (same path as a CLI dry-run).
        vm.setEnv("CONFIRM_MAINNET", "");
        Deploy script = new Deploy();
        (Prooflock escrow,) = script.run();
        assertTrue(address(escrow).code.length > 0);
    }
}

contract EthereumDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}

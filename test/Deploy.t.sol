// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployConfig} from "../script/DeployConfig.sol";
import {Prooflock} from "../src/Prooflock.sol";

contract DeployConfigTest is Test {
    function test_ethereumAndBaseUsdcAndFlags() public pure {
        DeployConfig.Chain memory e = DeployConfig.get(1);
        assertEq(e.usdc, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertTrue(e.isMainnet);
        DeployConfig.Chain memory b = DeployConfig.get(8453);
        assertEq(b.usdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertTrue(b.isMainnet);
    }

    function test_anvilConfigIsNotMainnet() public pure {
        DeployConfig.Chain memory c = DeployConfig.get(31337);
        assertEq(c.usdc, address(0));
        assertFalse(c.isMainnet);
    }

    function test_unsupportedChainReverts() public {
        vm.chainId(11155111); // Sepolia is not a supported target
        Deploy script = new Deploy();
        vm.expectRevert(bytes("DeployConfig: unsupported chain (only 1, 8453, 31337)"));
        script.run();
    }

    function test_deployScriptOnAnvilDeploysEscrowAndMockUsdc() public {
        if (block.chainid != 31337) {
            vm.skip(true);
            return;
        }
        Deploy script = new Deploy();
        (Prooflock escrow, address usdc) = script.run();
        assertTrue(address(escrow).code.length > 0);
        assertTrue(usdc.code.length > 0);
        assertEq(address(escrow.usdc()), usdc);
        assertEq(escrow.owner(), address(this));
        assertEq(escrow.feeRecipient(), address(this));
        assertEq(escrow.feeBps(), 0);
        assertEq(escrow.nextJobId(), 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/// @notice Полная диагностика проблемы с хуком
contract DiagnoseIssue is Script {
    address constant HOOK = 0xF43b5192d166CeCeb64255672Ef159d0771cd080;
    
    function run() external view {
        console.log("=== HOOK PROBLEM DIAGNOSIS ===");
        console.log("");
        
        // 1. Check address
        console.log("[1] HOOK ADDRESS");
        console.log("Address:", HOOK);
        
        uint160 flags = uint160(HOOK) & 0x3FFF;
        console.log("Low 14 bits:", flags);
        console.log("Expected:   ", uint160(0x0082));
        
        bool hasBEFORE_SWAP = (flags & 0x80) != 0;
        bool hasAFTER_INIT = (flags & 0x02) != 0;
        
        console.log("");
        console.log("Permission flags:");
        console.log("  BEFORE_SWAP (0x80):", hasBEFORE_SWAP ? "YES" : "NO");
        console.log("  AFTER_INIT (0x02): ", hasAFTER_INIT ? "YES" : "NO");
        
        // 2. Check deployment
        console.log("");
        console.log("[2] DEPLOYMENT STATUS");
        
        uint256 size;
        assembly { size := extcodesize(HOOK) }
        console.log("Code size:", size, "bytes");
        
        if (size == 0) {
            console.log("STATUS: Contract NOT deployed!");
            return;
        } else {
            console.log("STATUS: Contract IS deployed");
        }
        
        // 3. Analyze problem
        console.log("");
        console.log("[3] PROBLEM ANALYSIS");
        console.log("");
        
        if (!hasAFTER_INIT) {
            console.log("!!! CRITICAL PROBLEM !!!");
            console.log("  Hook address is MISSING AFTER_INITIALIZE flag!");
            console.log("");
            console.log("  This means:");
            console.log("  1. Hook was deployed WITHOUT afterInitialize() support");
            console.log("  2. PoolManager will REJECT afterInitialize() calls");
            console.log("  3. state.initialized will stay FALSE");
            console.log("  4. beforeSwap will think pool is not initialized");
            console.log("");
            console.log("CONSEQUENCES:");
            console.log("  - referenceTick = 0 (instead of real tick)");
            console.log("  - Any swap will trigger huge tickDelta");
            console.log("  - Pool will be in PERMANENT PANIC mode");
            console.log("  - Fee will ALWAYS be MAX (1.00% instead of 0.10%)");
            console.log("");
            console.log("RESULT: NOBODY WILL TRADE!");
            console.log("");
            console.log("SOLUTION:");
            console.log("  1. Redeploy hook with correct address (0x????...????_0082)");
            console.log("  2. Or modify code to NOT require afterInitialize");
            console.log("     (but then need different state initialization)");
        } else {
            console.log("Address flags are CORRECT");
            console.log("Problem may be elsewhere:");
            console.log("  - Check fees (MIN_FEE, PANIC_FEE)");
            console.log("  - Check TICK_THRESHOLD");
            console.log("  - Check pool liquidity");
        }
    }
}

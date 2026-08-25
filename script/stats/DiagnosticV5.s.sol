// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

interface IVolatilityHook {
    function isPanicking(PoolId id) external view returns (bool);
    function getState(PoolId id) external view returns (int24 referenceTick, uint256 panicExpiry, bool initialized);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
}

/// @title DiagnosticV5
/// @notice Диагностический скрипт для проверки состояния пула и хука
contract DiagnosticV5 is Script {

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH         = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT         = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() external view {
        address hookAddr = vm.envAddress("HOOK_ADDRESS_V5");

        console.log("=== Uniswap V4 Pool Diagnostic ===");
        console.log("Timestamp:", block.timestamp);
        console.log("Block:    ", block.number);
        console.log("");

        // ── 1. Проверка хука ──
        console.log("[1] HOOK CHECK");
        console.log("Hook address:", hookAddr);
        
        // Проверка адресных флагов
        uint160 addrBits = uint160(hookAddr) & 0x3FFF;
        console.log("Address bits (low 14):", addrBits);
        console.log("Expected (BEFORE_SWAP | AFTER_INIT):", uint160(0x0082));
        
        bool flagsOk = addrBits == 0x0082;
        console.log("Flags valid:", flagsOk ? "YES" : "NO");
        
        if (!flagsOk) {
            console.log("ERROR: Hook address does not match required permissions!");
            console.log("Swaps will FAIL because PoolManager rejects invalid hook addresses.");
            return;
        }

        // Проверка кода контракта
        uint256 codeSize;
        assembly { codeSize := extcodesize(hookAddr) }
        console.log("Hook code size:", codeSize);
        
        if (codeSize == 0) {
            console.log("ERROR: No code at hook address! Hook not deployed.");
            return;
        }

        // Проверка poolManager
        try IVolatilityHook(hookAddr).isPanicking(PoolId.wrap(bytes32(0))) returns (bool) {
            console.log("Hook responds: YES");
        } catch {
            console.log("Hook responds: NO (call reverted)");
            console.log("WARNING: Hook may be incompatible or broken.");
        }

        console.log("");

        // ── 2. Проверка пула ──
        console.log("[2] POOL CHECK");
        
        PoolKey memory key = PoolKey(
            Currency.wrap(WETH),
            Currency.wrap(USDT),
            0x800000,  // dynamic fee flag
            60,
            IHooks(hookAddr)
        );
        
        PoolId poolId = PoolIdLibrary.toId(key);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(poolId));
        
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        
        // Проверка инициализации пула
        (uint160 sqrtPriceX96, int24 currentTick, uint24 protocolFee, uint24 lpFee) = 
            StateLibrary.getSlot0(manager, poolId);
        
        if (sqrtPriceX96 == 0) {
            console.log("ERROR: Pool NOT initialized (sqrtPrice = 0)");
            console.log("Run InitPoolV5.s.sol first!");
            return;
        }
        
        console.log("Pool initialized: YES");
        console.log("sqrtPriceX96:", uint256(sqrtPriceX96));
        console.log("currentTick:");
        console.logInt(int256(currentTick));
        console.log("protocolFee:", protocolFee);
        console.log("lpFee:", lpFee);
        
        // Note: Liquidity check requires StateLibrary which causes compiler issues
        // Skip liquidity check in this simplified diagnostic version
        
        console.log("");

        // ── 3. Проверка состояния хука ──
        console.log("[3] HOOK STATE");
        
        try IVolatilityHook(hookAddr).getState(poolId) returns (
            int24 referenceTick,
            uint256 panicExpiry,
            bool initialized
        ) {
            console.log("Hook initialized:", initialized ? "YES" : "NO");
            
            if (!initialized) {
                console.log("ERROR: Hook state not initialized!");
                console.log("This will cause beforeSwap to use referenceTick = 0 in permanent panic mode.");
                console.log("Re-initialize pool or fix hook logic.");
                return;
            }
            
            console.log("Reference tick:");
            console.logInt(int256(referenceTick));
            
            int24 tickDelta = currentTick > referenceTick
                ? currentTick - referenceTick
                : referenceTick - currentTick;
            console.log("Tick delta (abs):");
            console.logInt(int256(tickDelta));
            
            bool isPanic = block.timestamp < panicExpiry;
            console.log("Panic mode:", isPanic ? "ACTIVE" : "normal");
            
            if (isPanic) {
                console.log("Panic expires in (sec):", panicExpiry - block.timestamp);
                console.log("Current fee: 1.00% (PANIC_FEE)");
                console.log("WARNING: High fee may block arbitrageurs!");
            } else {
                console.log("Current fee: 0.30% (MIN_FEE)");
                
                if (tickDelta >= 60) {  // V5 threshold
                    console.log("WARNING: Tick delta >= 60, next swap will trigger PANIC!");
                }
            }
        } catch Error(string memory reason) {
            console.log("ERROR reading hook state:", reason);
        } catch {
            console.log("ERROR: Hook does not implement getState() or call reverted.");
            console.log("May be using old VolatilityGuardHookV5 version without getState().");
        }
        
        console.log("");

        // ── 4. Проверка балансов токенов ──
        console.log("[4] TOKEN BALANCES (PoolManager)");
        
        uint256 wethBal = IERC20Like(WETH).balanceOf(POOL_MANAGER);
        uint256 usdtBal = IERC20Like(USDT).balanceOf(POOL_MANAGER);
        
        console.log("WETH balance:", wethBal);
        console.log("USDT balance:", usdtBal);
        
        if (wethBal == 0 && usdtBal == 0) {
            console.log("WARNING: PoolManager has zero token balances.");
            console.log("This is unusual if pool has liquidity.");
        }
        
        console.log("");

        // ── 5. Рекомендации ──
        console.log("[5] DIAGNOSTIC SUMMARY");
        console.log("=======================");
        
        bool allOk = true;
        
        if (!flagsOk) {
            console.log("BLOCKER: Hook address flags invalid");
            allOk = false;
        }
        
        if (sqrtPriceX96 == 0) {
            console.log("BLOCKER: Pool not initialized");
            allOk = false;
        }
        
        // Пытаемся проверить initialized через isPanicking (косвенная проверка)
        try IVolatilityHook(hookAddr).getState(poolId) returns (
            int24,
            uint256 panicExpiry,
            bool initialized
        ) {
            if (!initialized) {
                console.log("BLOCKER: Hook state not initialized");
                allOk = false;
            }
            
            if (block.timestamp < panicExpiry) {
                console.log("WARNING: Pool in PANIC mode (1% fee may reduce volume)");
            }
        } catch {
            console.log("WARNING: Cannot read hook state (may use old version)");
        }
        
        if (allOk) {
            console.log(">>> Pool appears HEALTHY and ready for swaps! <<<");
        } else {
            console.log(">>> Pool has CRITICAL ISSUES preventing swaps <<<");
            console.log("Fix issues above before attempting transactions.");
        }
    }
}

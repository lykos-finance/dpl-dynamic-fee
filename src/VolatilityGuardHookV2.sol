// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol"; 

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract VolatilityGuardHookV2 is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // --- IMMUTABLES ---
    IPoolManager public immutable poolManager;

    // --- CONSTANTS ---
    int24 public constant TICK_THRESHOLD = 60;      
    uint24 public constant BASE_FEE = 500;          // 0.05%
    uint24 public constant PANIC_FEE = 20000;       // 2.00%
    uint256 public constant PANIC_DURATION = 60;    
    uint256 public constant ANCHOR_LIFETIME = 300;  

    // --- STATE ---
    struct VolatilityState {
        int24 referenceTick;       
        uint256 lastUpdateTimestamp;
        uint256 panicExpiry;       
        bool isInitialized;
    }

    mapping(PoolId => VolatilityState) public states;

    // --- EVENTS (ЛОГИРОВАНИЕ) ---
    event PoolInitialized(
        PoolId indexed poolId,
        int24 initialTick,
        uint256 timestamp
    );

    event FeeApplied(
        PoolId indexed poolId,
        uint24 fee,
        string reason,
        int24 currentTick,
        int24 referenceTick,
        int24 tickDelta,
        uint256 timestamp
    );

    event PanicModeActivated(
        PoolId indexed poolId,
        int24 triggerTick,
        int24 referenceTick,
        int24 tickDelta,
        uint256 panicExpiry,
        uint256 timestamp
    );

    event PanicModeExtended(
        PoolId indexed poolId,
        uint256 newExpiry,
        uint256 timestamp
    );

    event AnchorUpdated(
        PoolId indexed poolId,
        int24 oldTick,
        int24 newTick,
        string reason,
        uint256 timestamp
    );

    event StaleAnchorReset(
        PoolId indexed poolId,
        int24 oldTick,
        int24 newTick,
        uint256 timeSinceLastUpdate,
        uint256 timestamp
    );

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "Not PoolManager");
        _;
    }

    // --- PERMISSIONS ---
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,       
            afterInitialize: false,        
            beforeAddLiquidity: false,      
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,             
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- MAIN LOGIC (beforeSwap) ---
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata, 
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        
        PoolId poolId = key.toId();
        VolatilityState storage state = states[poolId];
        
        ( , int24 currentTick, , ) = poolManager.getSlot0(poolId);

        // 1. Инициализация
        if (!state.isInitialized) {
            state.referenceTick = currentTick;
            state.lastUpdateTimestamp = block.timestamp;
            state.isInitialized = true;
            
            emit PoolInitialized(poolId, currentTick, block.timestamp);
            emit FeeApplied(poolId, BASE_FEE, "initialization", currentTick, currentTick, 0, block.timestamp);
            
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE | 0x400000); 
        }

        uint24 feeToApply = BASE_FEE;
        bool updateAnchor = false;
        int24 oldReferenceTick = state.referenceTick;

        // A. Panic Check
        if (block.timestamp < state.panicExpiry) {
            feeToApply = PANIC_FEE;
            state.panicExpiry = block.timestamp + PANIC_DURATION;
            updateAnchor = true;
            
            emit PanicModeExtended(poolId, state.panicExpiry, block.timestamp);
            emit FeeApplied(poolId, PANIC_FEE, "panic_mode_active", currentTick, state.referenceTick, 
                currentTick > state.referenceTick ? currentTick - state.referenceTick : state.referenceTick - currentTick, 
                block.timestamp);
        } 
        // B. Stale Check
        else if (block.timestamp > state.lastUpdateTimestamp + ANCHOR_LIFETIME) {
            feeToApply = BASE_FEE;
            updateAnchor = true;
            
            uint256 timeSinceUpdate = block.timestamp - state.lastUpdateTimestamp;
            emit StaleAnchorReset(poolId, oldReferenceTick, currentTick, timeSinceUpdate, block.timestamp);
            emit FeeApplied(poolId, BASE_FEE, "stale_anchor", currentTick, oldReferenceTick, 
                currentTick > oldReferenceTick ? currentTick - oldReferenceTick : oldReferenceTick - currentTick, 
                block.timestamp);
        }
        // C. Volatility Check
        else {
            int24 delta = currentTick > state.referenceTick 
                ? currentTick - state.referenceTick 
                : state.referenceTick - currentTick;

            if (delta >= TICK_THRESHOLD) {
                feeToApply = PANIC_FEE;
                state.panicExpiry = block.timestamp + PANIC_DURATION;
                updateAnchor = true;
                
                emit PanicModeActivated(poolId, currentTick, state.referenceTick, delta, state.panicExpiry, block.timestamp);
                emit FeeApplied(poolId, PANIC_FEE, "volatility_threshold_exceeded", currentTick, state.referenceTick, delta, block.timestamp);
            } else {
                feeToApply = BASE_FEE;
                updateAnchor = false;
                
                emit FeeApplied(poolId, BASE_FEE, "normal", currentTick, state.referenceTick, delta, block.timestamp);
            }
        }

        if (updateAnchor) {
            state.referenceTick = currentTick;
            state.lastUpdateTimestamp = block.timestamp;
            
            string memory updateReason = feeToApply == PANIC_FEE ? "panic_triggered" : "stale_reset";
            emit AnchorUpdated(poolId, oldReferenceTick, currentTick, updateReason, block.timestamp);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeToApply | 0x400000);
    }

    // --- SAFETY STUBS (FIXED SIGNATURES) ---

    function beforeInitialize(address, PoolKey calldata, uint160) external override onlyPoolManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external override onlyPoolManager returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external override onlyPoolManager returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external override onlyPoolManager returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external override onlyPoolManager returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external override onlyPoolManager returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external override onlyPoolManager returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
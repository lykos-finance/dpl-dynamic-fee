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
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/// @title VolatilityGuardHookV3 (trustless)
/// @notice Dynamic-fee hook with panic mode, per-block caching, and directional asymmetry.
///
/// Design:
///  - Flash-loan resistant: reads the block-start tick snapshot, not mid-block live tick.
///  - Panic cap: total panic cannot be extended beyond PANIC_HARD_CAP from initial trigger.
///  - Directional discount only when tick is already far from reference (real rebalance).
///  - Fully immutable: no owner, no pause, no admin keys — trustless by design.
contract VolatilityGuardHookV3 is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // --- IMMUTABLES ---
    IPoolManager public immutable poolManager;

    // --- FEE CONSTANTS (pips, 1e6 = 100%) ---
    uint24 public constant BASE_FEE         = 2500;    // 0.25% — нормальный режим
    uint24 public constant PANIC_FEE        = 3000;    // 0.30% — максимум при волатильности
    uint24 public constant REWARD_FEE       = 1000;    // 0.10% — counter-trend reward (floor)
    uint24 public constant DIRECTIONAL_BUMP = 200;     // +/-0.02% (small to keep tiers distinct)


    // --- THRESHOLDS ---
    int24   public constant TICK_THRESHOLD         = 60;     // normal panic trigger
    int24   public constant STALE_TICK_THRESHOLD   = 150;    // stale-path panic trigger
    int24   public constant REBALANCE_MIN_DELTA    = 60;     // min delta to qualify for discount
    uint256 public constant PANIC_DURATION         = 60;     // seconds per extension
    uint256 public constant PANIC_HARD_CAP         = 600;    // max total panic window (10 min)
    uint256 public constant ANCHOR_LIFETIME        = 1800;   // 30 min

    // --- STATE (internal, no MEV leak) ---
    struct VolatilityState {
        int24   referenceTick;
        uint256 lastUpdateTimestamp;
        uint256 panicExpiry;
        uint256 panicStartedAt;     
        bool    isInitialized;

        uint256 lastBlockNumber;
        int24   blockStartTick;     
        uint24  cachedFee;
        bool    cachedDirection;
    }

    mapping(PoolId => VolatilityState) internal _states;

    // --- EVENTS ---
    event PoolInitialized(PoolId indexed poolId, int24 initialTick, uint256 timestamp);
    event FeeApplied(
        PoolId  indexed poolId,
        uint24  fee,
        string  reason,
        int24   currentTick,
        int24   referenceTick,
        int24   tickDelta,
        uint256 timestamp
    );
    event PanicModeActivated(PoolId indexed poolId, int24 triggerTick, int24 referenceTick, int24 tickDelta, uint256 panicExpiry, uint256 timestamp);
    event PanicModeExtended(PoolId indexed poolId, uint256 newExpiry, uint256 timestamp);
    event PanicHardCapReached(PoolId indexed poolId, uint256 timestamp);
    event AnchorUpdated(PoolId indexed poolId, int24 oldTick, int24 newTick, string reason, uint256 timestamp);
    event StaleAnchorReset(PoolId indexed poolId, int24 oldTick, int24 newTick, uint256 timeSinceLastUpdate, uint256 timestamp);
    event BlockCacheHit(PoolId indexed poolId, uint24 fee, uint256 blockNumber);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "Not PoolManager");
        _;
    }

    // --- READ-ONLY ACCESSORS (no sensitive fields leaked) ---
    function isInitialized(PoolId id) external view returns (bool) { return _states[id].isInitialized; }
    function referenceTick(PoolId id) external view returns (int24) { return _states[id].referenceTick; }
    function panicExpiry(PoolId id) external view returns (uint256) { return _states[id].panicExpiry; }

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

    // --- MAIN LOGIC ---
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        VolatilityState storage state = _states[poolId];
        (, int24 liveTick, , ) = poolManager.getSlot0(poolId);

        // ── 0. First-ever swap ──
        if (!state.isInitialized) {
            state.referenceTick = liveTick;
            state.lastUpdateTimestamp = block.timestamp;
            state.lastBlockNumber = block.number;
            state.blockStartTick = liveTick;
            state.cachedFee = BASE_FEE;
            state.cachedDirection = params.zeroForOne;
            state.isInitialized = true;

            emit PoolInitialized(poolId, liveTick, block.timestamp);
            emit FeeApplied(poolId, BASE_FEE, "initialization", liveTick, liveTick, 0, block.timestamp);
            return _return(BASE_FEE);
        }

        // ── 1. Per-block cache (Arrakis pattern) ──
        // SECURITY: if within the same block, we use the cached fee AND detect any
        // mid-block tick manipulation by comparing to blockStartTick (flash-loan guard).
        if (block.number == state.lastBlockNumber) {
            int24 midBlockDrift = _absDelta(liveTick, state.blockStartTick);
            // If price moved suspiciously far mid-block (likely flash-loan manipulation)
            // we fall back to PANIC_FEE regardless of cached value.
            uint24 fee = midBlockDrift >= TICK_THRESHOLD
                ? PANIC_FEE
                : _applyDirectionalAdjustment(state.cachedFee, state.cachedDirection, params.zeroForOne, liveTick, state.referenceTick);
            if (fee > PANIC_FEE) fee = PANIC_FEE; // sanity clamp
            emit BlockCacheHit(poolId, fee, block.number);
            return _return(fee);
        }

        // ── 2. New block → snapshot blockStartTick BEFORE computing ──
        // This is the tick we trust; any later mid-block move is treated as manipulation.
        int24 blockStart = liveTick;

        uint24 newFee;
        string memory reason;
        bool updateAnchor = false;
        bool activatePanic = false;
        int24 oldRef = state.referenceTick;

        // A. Panic still active
        if (block.timestamp < state.panicExpiry) {
            newFee = PANIC_FEE;
            reason = "panic_mode_active";
            // SECURITY: extend only if within the hard cap from initial trigger.
            if (block.timestamp < state.panicStartedAt + PANIC_HARD_CAP) {
                state.panicExpiry = block.timestamp + PANIC_DURATION;
                emit PanicModeExtended(poolId, state.panicExpiry, block.timestamp);
            } else {
                // Cap reached: let the current window expire naturally, no further extension.
                emit PanicHardCapReached(poolId, block.timestamp);
            }
        }
        // B. Stale anchor — with volatility check (V2 fix)
        else if (block.timestamp > state.lastUpdateTimestamp + ANCHOR_LIFETIME) {
            int24 d = _absDelta(blockStart, oldRef);
            if (d >= STALE_TICK_THRESHOLD) {
                newFee = PANIC_FEE;
                reason = "stale_large_drift";
                activatePanic = true;
            } else {
                newFee = BASE_FEE;
                reason = "stale_anchor";
            }
            updateAnchor = true;
            emit StaleAnchorReset(poolId, oldRef, blockStart, block.timestamp - state.lastUpdateTimestamp, block.timestamp);
        }
        // C. Normal volatility check
        else {
            int24 d = _absDelta(blockStart, oldRef);
            if (d >= TICK_THRESHOLD) {
                newFee = PANIC_FEE;
                reason = "volatility_threshold_exceeded";
                activatePanic = true;
                updateAnchor = true;
            } else {
                newFee = BASE_FEE;
                reason = "normal";
            }
        }

        if (activatePanic) {
            state.panicExpiry = block.timestamp + PANIC_DURATION;
            state.panicStartedAt = block.timestamp; // for hard cap
            emit PanicModeActivated(poolId, blockStart, oldRef, _absDelta(blockStart, oldRef), state.panicExpiry, block.timestamp);
        }
        if (updateAnchor) {
            state.referenceTick = blockStart;
            state.lastUpdateTimestamp = block.timestamp;
            emit AnchorUpdated(poolId, oldRef, blockStart, reason, block.timestamp);
        }

        // Direction of the move since last anchor
        bool lastDirectionZFO = blockStart < oldRef;

        state.lastBlockNumber = block.number;
        state.blockStartTick = blockStart;
        state.cachedFee = newFee;
        state.cachedDirection = lastDirectionZFO;

        uint24 finalFee = _applyDirectionalAdjustment(newFee, lastDirectionZFO, params.zeroForOne, blockStart, state.referenceTick);
        // Sanity clamp — never exceed PANIC_FEE.
        if (finalFee > PANIC_FEE) finalFee = PANIC_FEE;
        emit FeeApplied(poolId, finalFee, reason, blockStart, oldRef, _absDelta(blockStart, oldRef), block.timestamp);

        return _return(finalFee);
    }

    // --- HELPERS ---

    function _absDelta(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a - b : b - a;
    }

    /// @dev Trend-following charges more. Counter-trend gets discount ONLY when pool is meaningfully
    ///      misaligned (|delta from ref| >= REBALANCE_MIN_DELTA) — prevents self-sandwich gaming.
    function _applyDirectionalAdjustment(
        uint24 baseFee,
        bool lastMoveZFO,
        bool swapZFO,
        int24 currentTick,
        int24 refTick
    ) internal pure returns (uint24) {
        if (baseFee >= PANIC_FEE) {
            return baseFee; // no tweaks during panic
        }

        int24 delta = currentTick > refTick ? currentTick - refTick : refTick - currentTick;

        if (lastMoveZFO == swapZFO) {
            // Trend-following tax
            uint24 bumped = baseFee + DIRECTIONAL_BUMP;
            return bumped > PANIC_FEE ? PANIC_FEE : bumped;
        }
        // Counter-trend: reward ONLY if the pool is misaligned enough to justify rebalance.
        if (delta < REBALANCE_MIN_DELTA) {
            return baseFee;
        }
        return baseFee > (REWARD_FEE + DIRECTIONAL_BUMP)
            ? baseFee - DIRECTIONAL_BUMP
            : REWARD_FEE;
    }

    function _return(uint24 fee) internal pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // --- SAFETY STUBS ---

    function beforeInitialize(address, PoolKey calldata, uint160) external view override onlyPoolManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view override onlyPoolManager returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external view override onlyPoolManager returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }
    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }
    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external view override onlyPoolManager returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }
    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external view override onlyPoolManager returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external view override onlyPoolManager returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external view override onlyPoolManager returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}

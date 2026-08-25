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

/// @title VolatilityGuardHookV4 (Arbitrum-tuned)
/// @notice V3 with timestamp-based cache window (chain-agnostic) + tighter parameters
///         for high-frequency L2 markets.
///
/// Key differences from V3:
///   - Cache uses block.timestamp + CACHE_WINDOW (2 s) instead of block.number
///     → works reliably on chains with non-standard block.number behaviour (Arbitrum L1 number,
///       Optimism L2 rollup, etc.).
///   - ANCHOR_LIFETIME shortened (10 min vs 30 min) — more frequent trading on L2.
///   - PANIC_DURATION shortened (15 s vs 60 s) — faster reversion on fast chains.
///   - TICK_THRESHOLD tightened (40 ticks ≈ 0.4%) — tighter L2 spreads.
contract VolatilityGuardHookV4 is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // --- IMMUTABLES ---
    IPoolManager public immutable poolManager;
    address public immutable owner;

    // --- FEE CONSTANTS ---
    uint24 public constant BASE_FEE         = 2500;    
    uint24 public constant PANIC_FEE        = 9000;  
    uint24 public constant REWARD_FEE       = 1000;    
    uint24 public constant EMERGENCY_FEE    = 100_000; 
    uint24 public constant DIRECTIONAL_BUMP = 500;

    // --- THRESHOLDS (Arbitrum-tuned) ---
    int24   public constant TICK_THRESHOLD        = 40;  
    int24   public constant STALE_TICK_THRESHOLD  = 100;  
    int24   public constant REBALANCE_MIN_DELTA   = 40;    
    uint256 public constant PANIC_DURATION        = 15;   
    uint256 public constant PANIC_HARD_CAP        = 300;  
    uint256 public constant ANCHOR_LIFETIME       = 600;   
    uint256 public constant CACHE_WINDOW          = 2;   
    uint256 public constant MAX_PAUSE_DURATION    = 3 days;

    // --- STATE ---
    struct VolatilityState {
        int24   referenceTick;
        uint256 lastUpdateTimestamp;
        uint256 panicExpiry;
        uint256 panicStartedAt;
        bool    isInitialized;

        uint256 cacheExpiry;          // timestamp when the cache becomes stale
        int24   windowStartTick;      // snapshot at first swap of the window
        uint24  cachedFee;
        bool    cachedDirection;
    }

    mapping(PoolId => VolatilityState) internal _states;

    // --- EMERGENCY ---
    bool private _paused;
    uint256 public pausedAt;

    // --- EVENTS ---
    event PoolInitialized(PoolId indexed poolId, int24 initialTick, uint256 timestamp);
    event FeeApplied(PoolId indexed poolId, uint24 fee, string reason, int24 currentTick, int24 referenceTick, int24 tickDelta, uint256 timestamp);
    event PanicModeActivated(PoolId indexed poolId, int24 triggerTick, int24 referenceTick, int24 tickDelta, uint256 panicExpiry, uint256 timestamp);
    event PanicModeExtended(PoolId indexed poolId, uint256 newExpiry, uint256 timestamp);
    event PanicHardCapReached(PoolId indexed poolId, uint256 timestamp);
    event AnchorUpdated(PoolId indexed poolId, int24 oldTick, int24 newTick, string reason, uint256 timestamp);
    event StaleAnchorReset(PoolId indexed poolId, int24 oldTick, int24 newTick, uint256 timeSinceLastUpdate, uint256 timestamp);
    event CacheHit(PoolId indexed poolId, uint24 fee, uint256 timestamp);
    event EmergencyPaused(address by);
    event EmergencyUnpaused(address by);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        owner = msg.sender;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "Not PoolManager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // --- EMERGENCY ---
    function pause() external onlyOwner {
        _paused = true;
        pausedAt = block.timestamp;
        emit EmergencyPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        _paused = false;
        pausedAt = 0;
        emit EmergencyUnpaused(msg.sender);
    }

    function paused() public view returns (bool) {
        if (!_paused) return false;
        return block.timestamp < pausedAt + MAX_PAUSE_DURATION;
    }

    // --- READ-ONLY ACCESSORS ---
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
        if (paused()) return _return(EMERGENCY_FEE);

        PoolId poolId = key.toId();
        VolatilityState storage state = _states[poolId];
        (, int24 liveTick, , ) = poolManager.getSlot0(poolId);

        // ── 0. First-ever swap ──
        if (!state.isInitialized) {
            state.referenceTick = liveTick;
            state.lastUpdateTimestamp = block.timestamp;
            state.cacheExpiry = block.timestamp + CACHE_WINDOW;
            state.windowStartTick = liveTick;
            state.cachedFee = BASE_FEE;
            state.cachedDirection = params.zeroForOne;
            state.isInitialized = true;

            emit PoolInitialized(poolId, liveTick, block.timestamp);
            emit FeeApplied(poolId, BASE_FEE, "initialization", liveTick, liveTick, 0, block.timestamp);
            return _return(BASE_FEE);
        }

        // ── 1. Cache window still valid → use cached fee, but detect mid-window manipulation ──
        if (block.timestamp < state.cacheExpiry) {
            int24 midDrift = _absDelta(liveTick, state.windowStartTick);
            uint24 fee = midDrift >= TICK_THRESHOLD
                ? PANIC_FEE
                : _applyDirectionalAdjustment(state.cachedFee, state.cachedDirection, params.zeroForOne, liveTick, state.referenceTick);
            if (fee > PANIC_FEE) fee = PANIC_FEE;
            emit CacheHit(poolId, fee, block.timestamp);
            return _return(fee);
        }

        // ── 2. New window → recompute ──
        int24 windowStart = liveTick;

        uint24 newFee;
        string memory reason;
        bool updateAnchor = false;
        bool activatePanic = false;
        int24 oldRef = state.referenceTick;

        if (block.timestamp < state.panicExpiry) {
            newFee = PANIC_FEE;
            reason = "panic_mode_active";
            if (block.timestamp < state.panicStartedAt + PANIC_HARD_CAP) {
                state.panicExpiry = block.timestamp + PANIC_DURATION;
                emit PanicModeExtended(poolId, state.panicExpiry, block.timestamp);
            } else {
                emit PanicHardCapReached(poolId, block.timestamp);
            }
        } else if (block.timestamp > state.lastUpdateTimestamp + ANCHOR_LIFETIME) {
            int24 d = _absDelta(windowStart, oldRef);
            if (d >= STALE_TICK_THRESHOLD) {
                newFee = PANIC_FEE;
                reason = "stale_large_drift";
                activatePanic = true;
            } else {
                newFee = BASE_FEE;
                reason = "stale_anchor";
            }
            updateAnchor = true;
            emit StaleAnchorReset(poolId, oldRef, windowStart, block.timestamp - state.lastUpdateTimestamp, block.timestamp);
        } else {
            int24 d = _absDelta(windowStart, oldRef);
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
            state.panicStartedAt = block.timestamp;
            emit PanicModeActivated(poolId, windowStart, oldRef, _absDelta(windowStart, oldRef), state.panicExpiry, block.timestamp);
        }
        if (updateAnchor) {
            state.referenceTick = windowStart;
            state.lastUpdateTimestamp = block.timestamp;
            emit AnchorUpdated(poolId, oldRef, windowStart, reason, block.timestamp);
        }

        bool lastDirectionZFO = windowStart < oldRef;

        state.cacheExpiry = block.timestamp + CACHE_WINDOW;
        state.windowStartTick = windowStart;
        state.cachedFee = newFee;
        state.cachedDirection = lastDirectionZFO;

        uint24 finalFee = _applyDirectionalAdjustment(newFee, lastDirectionZFO, params.zeroForOne, windowStart, state.referenceTick);
        if (finalFee > PANIC_FEE) finalFee = PANIC_FEE;
        emit FeeApplied(poolId, finalFee, reason, windowStart, oldRef, _absDelta(windowStart, oldRef), block.timestamp);

        return _return(finalFee);
    }

    // --- HELPERS ---

    function _absDelta(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a - b : b - a;
    }

    function _applyDirectionalAdjustment(
        uint24 baseFee,
        bool lastMoveZFO,
        bool swapZFO,
        int24 currentTick,
        int24 refTick
    ) internal pure returns (uint24) {
        if (baseFee >= PANIC_FEE) return baseFee;
        int24 delta = currentTick > refTick ? currentTick - refTick : refTick - currentTick;
        if (lastMoveZFO == swapZFO) {
            uint24 bumped = baseFee + DIRECTIONAL_BUMP;
            return bumped > PANIC_FEE ? PANIC_FEE : bumped;
        }
        if (delta < REBALANCE_MIN_DELTA) return baseFee;
        return baseFee > (REWARD_FEE + DIRECTIONAL_BUMP) ? baseFee - DIRECTIONAL_BUMP : REWARD_FEE;
    }

    function _return(uint24 fee) internal pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // --- SAFETY STUBS ---
    function beforeInitialize(address, PoolKey calldata, uint160) external view override onlyPoolManager returns (bytes4) { return IHooks.beforeInitialize.selector; }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view override onlyPoolManager returns (bytes4) { return IHooks.afterInitialize.selector; }
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external view override onlyPoolManager returns (bytes4) { return IHooks.beforeAddLiquidity.selector; }
    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external view override onlyPoolManager returns (bytes4, BalanceDelta) { return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0)); }
    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external view override onlyPoolManager returns (bytes4) { return IHooks.beforeRemoveLiquidity.selector; }
    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external view override onlyPoolManager returns (bytes4, BalanceDelta) { return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0)); }
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external view override onlyPoolManager returns (bytes4, int128) { return (IHooks.afterSwap.selector, 0); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external view override onlyPoolManager returns (bytes4) { return IHooks.beforeDonate.selector; }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external view override onlyPoolManager returns (bytes4) { return IHooks.afterDonate.selector; }
}

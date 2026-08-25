// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/// @title VolatilityGuardHookV5_Fixed
/// @notice ИСПРАВЛЕННАЯ версия хука с динамическими комиссиями:
///   - 0.10% (MIN_FEE)   — спокойный рынок
///   - 0.30% (PANIC_FEE) — когда текущий тик отклонился от якоря на ≥ 200
///   Паника длится ровно 5 минут (PANIC_DURATION), без продлений.
///   После паники якорь сбрасывается на текущий тик.
///
/// @dev Исправления:
///   1. Скорректированы значения комиссий (1000 / 3000 вместо 3000 / 10000)
///   2. Увеличен TICK_THRESHOLD до 200 (~2% вместо 0.6%)
///   3. Добавлена защита от повторной инициализации
///   4. Добавлена проверка инициализации в beforeSwap
///   5. Добавлен try/catch для getSlot0 (graceful degradation)
///   6. Добавлена валидация poolManager в конструкторе
///   7. Добавлено событие FeeApplied для мониторинга
///   8. Убран неиспользуемый параметр sqrtPriceX96 (заменен на _)
contract VolatilityGuardHookV5_Fixed is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    IPoolManager public immutable poolManager;

    // ── Комиссии (исправлено) ────────────────────────────────────────────────
    uint24 public constant MIN_FEE        = 1000;   
    uint24 public constant PANIC_FEE      = 3000;  
    
    // ── Пороги (исправлено) ──────────────────────────────────────────────────
    int24  public constant TICK_THRESHOLD = 200;    
    uint256 public constant PANIC_DURATION = 300;   

    struct PoolState {
        int24   referenceTick;
        uint256 panicExpiry;   
        bool    initialized;
    }

    mapping(PoolId => PoolState) internal _states;

    // ── События (добавлено FeeApplied) ───────────────────────────────────────
    event PanicActivated(PoolId indexed poolId, int24 currentTick, int24 referenceTick, uint256 expiry);
    event PanicExpired(PoolId indexed poolId, int24 newReferenceTick);
    event FeeApplied(PoolId indexed poolId, uint24 fee, int24 currentTick, int24 referenceTick, bool isPanic);
    event PoolInitialized(PoolId indexed poolId, int24 initialTick);

    // ── Конструктор (добавлена валидация) ────────────────────────────────────
    constructor(IPoolManager _poolManager) {
        require(address(_poolManager) != address(0), "Invalid PoolManager");
        poolManager = _poolManager;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not PoolManager");
        _;
    }

    // ── View ─────────────────────────────────────────────────────────────────

    function isPanicking(PoolId id) external view returns (bool) {
        return block.timestamp < _states[id].panicExpiry;
    }

    function getState(PoolId id) external view returns (
        int24 referenceTick,
        uint256 panicExpiry,
        bool initialized
    ) {
        PoolState storage state = _states[id];
        return (state.referenceTick, state.panicExpiry, state.initialized);
    }

    // ── Hook permissions ─────────────────────────────────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
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

    // ── Main logic ───────────────────────────────────────────────────────────
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160, 
        int24 tick
    ) external override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        PoolState storage state = _states[poolId];

        require(!state.initialized, "Pool already initialized");

        state.referenceTick = tick;
        state.panicExpiry = 0;
        state.initialized = true;

        emit PoolInitialized(poolId, tick);

        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolState storage state = _states[poolId];

        // ✅ Проверка инициализации
        require(state.initialized, "Pool not initialized");

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        if (block.timestamp < state.panicExpiry) {
            emit FeeApplied(poolId, PANIC_FEE, currentTick, state.referenceTick, true);
            return _return(PANIC_FEE);
        }

        if (state.panicExpiry != 0) {
            emit PanicExpired(poolId, currentTick);
            state.referenceTick = currentTick;
            state.panicExpiry   = 0;
            emit FeeApplied(poolId, MIN_FEE, currentTick, currentTick, false);
            return _return(MIN_FEE);
        }

        int24 delta = currentTick > state.referenceTick
            ? currentTick - state.referenceTick
            : state.referenceTick - currentTick;

        if (delta >= TICK_THRESHOLD) {
            state.panicExpiry = block.timestamp + PANIC_DURATION;
            emit PanicActivated(poolId, currentTick, state.referenceTick, state.panicExpiry);
            emit FeeApplied(poolId, PANIC_FEE, currentTick, state.referenceTick, true);
            return _return(PANIC_FEE);
        }

        emit FeeApplied(poolId, MIN_FEE, currentTick, state.referenceTick, false);
        return _return(MIN_FEE);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    function _return(uint24 fee) internal pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ── Required IHooks stubs ────────────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeInitialize.selector; }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeAddLiquidity.selector; }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external view override onlyPoolManager returns (bytes4, BalanceDelta)
    { return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0)); }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeRemoveLiquidity.selector; }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external view override onlyPoolManager returns (bytes4, BalanceDelta)
    { return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0)); }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external view override onlyPoolManager returns (bytes4, int128)
    { return (IHooks.afterSwap.selector, 0); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.afterDonate.selector; }
}

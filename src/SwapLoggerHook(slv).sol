// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/// @title SwapLoggerHook
/// @notice Хук для пары WETH/USDC. Единственная реальная логика — эмит события
///         afterSwap. Комиссия формально "динамическая" (для вида): beforeSwap
///         override-ит fee в узком коридоре 0.30%-0.31% (3000-3100 бипс), без
///         какой-либо привязки к волатильности или объёму. Реализован напрямую
///         через IHooks, без BaseHook (в установленной версии v4-periphery
///         BaseHook.sol отсутствует).
contract SwapLoggerHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    IPoolManager public immutable poolManager;

    /// @dev 2-из-2 мультисиг: любое админ-действие должен предложить один
    ///      owner и подтвердить (исполнить) второй. Один скомпрометированный
    ///      ключ ничего сам по себе сделать не может.
    address public owner1;
    address public owner2;
    uint256 public actionNonce;

    struct Action {
        address proposer;
        bool executed;
    }
    mapping(bytes32 => Action) public actions;

    bool public loggingEnabled = true;

    // ── "Косметическая" динамическая комиссия ──
    // Диапазон 3000-3100 бипс = 0.30%-0.31%. Никакой реальной логики волатильности,
    // просто лёгкий детерминированный разброс на основе блока/пула, чтобы комиссия
    // формально менялась от свопа к свопу.
    uint24 public constant FEE_MIN = 3000; // 0.30%
    uint24 public constant FEE_MAX = 3100; // 0.31%
    uint24 public constant FEE_RANGE = FEE_MAX - FEE_MIN + 1; // 101 возможных значений

    event SwapLogged(
        address indexed sender,
        PoolId indexed poolId,
        int256 amount0,
        int256 amount1,
        uint256 timestamp
    );

    event ActionProposed(bytes32 indexed actionId, address indexed proposer, bytes data);
    event ActionExecuted(bytes32 indexed actionId, address indexed executor);
    event OwnerChanged(uint8 indexed slot, address indexed oldOwner, address indexed newOwner);
    event LoggingToggled(bool enabled);

    error NotOwner();
    error ZeroAddress();
    error SameOwner();
    error NoSuchAction();
    error AlreadyExecuted();
    error MustBeOtherOwner();
    error ExecutionFailed();
    error OnlySelf();
    error NotPoolManager();
    error HookNotImplemented();

    modifier onlyOwners() {
        if (msg.sender != owner1 && msg.sender != owner2) revert NotOwner();
        _;
    }

    /// @dev Целевые админ-функции (setLoggingEnabled, setOwner) вызываются
    ///      только через confirmAndExecute -> address(this).call(...),
    ///      напрямую их не вызвать даже владельцам.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _owner1, address _owner2) {
        if (_owner1 == address(0) || _owner2 == address(0)) revert ZeroAddress();
        if (_owner1 == _owner2) revert SameOwner();
        poolManager = _poolManager;
        owner1 = _owner1;
        owner2 = _owner2;

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ---------------------------------------------------------------
    // Мультисиг: propose -> confirmAndExecute
    // ---------------------------------------------------------------

    /// @notice Первый owner предлагает действие (calldata целевой функции этого контракта).
    /// @param data например abi.encodeCall(this.setLoggingEnabled, (false))
    function propose(bytes calldata data) external onlyOwners returns (bytes32 actionId) {
        actionId = keccak256(abi.encode(data, actionNonce, address(this)));
        actions[actionId] = Action({proposer: msg.sender, executed: false});
        actionNonce++;
        emit ActionProposed(actionId, msg.sender, data);
    }

    /// @notice Второй owner (не тот, кто предложил) подтверждает и исполняет действие.
    function confirmAndExecute(bytes32 actionId, bytes calldata data) external onlyOwners {
        Action storage a = actions[actionId];
        if (a.proposer == address(0)) revert NoSuchAction();
        if (a.executed) revert AlreadyExecuted();
        if (msg.sender == a.proposer) revert MustBeOtherOwner();

        a.executed = true;

        (bool ok, ) = address(this).call(data);
        if (!ok) revert ExecutionFailed();

        emit ActionExecuted(actionId, msg.sender);
    }

    /// @dev Включены beforeSwap (override комиссии "для вида") и afterSwap (логирование).
    ///      Всё остальное выключено — PoolManager эти колбэки даже не вызовет.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------
    // IHooks — реализация всех колбэков напрямую (без BaseHook)
    // ---------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @notice "Косметическая" динамическая комиссия: override в диапазоне 0.30%-0.31%.
    ///         Разброс детерминирован (блок + poolId + sender), никакой реальной
    ///         привязки к волатильности/объёму нет — исключительно для вида.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 rnd = uint256(
            keccak256(abi.encode(blockhash(block.number - 1), key.toId(), sender, block.timestamp))
        ) % FEE_RANGE;

        uint24 fee = FEE_MIN + uint24(rnd);
        uint24 feeWithOverride = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithOverride);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (loggingEnabled) {
            emit SwapLogged(
                sender,
                key.toId(),
                delta.amount0(),
                delta.amount1(),
                block.timestamp
            );
        }
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------
    // Целевые админ-функции — исполняются ТОЛЬКО через confirmAndExecute
    // ---------------------------------------------------------------

    function setLoggingEnabled(bool _enabled) external onlySelf {
        loggingEnabled = _enabled;
        emit LoggingToggled(_enabled);
    }

    /// @param slot 1 -> заменить owner1, 2 -> заменить owner2
    function setOwner(uint8 slot, address newOwner) external onlySelf {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == owner1 || newOwner == owner2) revert SameOwner();

        if (slot == 1) {
            emit OwnerChanged(1, owner1, newOwner);
            owner1 = newOwner;
        } else if (slot == 2) {
            emit OwnerChanged(2, owner2, newOwner);
            owner2 = newOwner;
        } else {
            revert("bad slot");
        }
    }
}
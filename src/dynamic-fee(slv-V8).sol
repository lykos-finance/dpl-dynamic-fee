// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/// @title VolatilityGuardHookV8
/// @notice Total swap fee scales linearly from 0.01% to 2% with the distance between the
///         pool tick and a time-weighted anchor tick. Part of that fee goes to the treasury.
///
/// Fee model:
///   - deviation <= CALM_TICKS -> MIN_FEE, deviation >= FULL_TICKS -> MAX_FEE, linear in between
///   - beforeSwap charges the fee for the pre-swap tick
///   - afterSwap tops it up if the swap's own price move earned a higher fee
///   - the anchor follows the tick by time only, so splitting a move into many swaps
///     or sending dust swaps cannot move it faster or hold the fee up
///
/// Fee split (TREASURY_BPS, 10%):
///   - LPs receive the rest of the total fee, the treasury share is sent in the same swap
///   - if that transfer fails the share stays in the hook as ERC-6909 claims, so swaps are never blocked
///   - anyone can then push those claims to the treasury, they cannot go anywhere else
///
/// Limits:
///   - all fee and anchor parameters are constants and cannot be changed by any role
///   - a Uniswap protocol fee (max 0.1%), if governance enables it, is charged on top of MAX_FEE
///
/// Access model:
///   2-of-2 signers with a 15 minute timelock, same pattern as ArbCaptureHook. Their only power is
///   replacing the treasury: they cannot pause swaps, change fees or touch liquidity.
///   Signers cannot be replaced.
///   A proposal must be confirmed within CONFIRM_WINDOW and executed within EXECUTE_WINDOW
///   after the timelock, otherwise it expires and has to be proposed again.
contract VolatilityGuardHookV8 is IHooks, IUnlockCallback {
    using PoolIdLibrary  for PoolKey;
    using StateLibrary   for IPoolManager;
    using LPFeeLibrary   for uint24;
    using CurrencyLibrary for Currency;

    // Fee limits (pips, 1e6 = 100%)

    uint24  public constant MIN_FEE = 100;     // 0.01%
    uint24  public constant MAX_FEE = 20_000;  // 2.00%

    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant PIPS_DENOMINATOR = 1_000_000;
    uint256 public constant TREASURY_BPS     = 1_000;   // 10% of the total fee

    uint256 public constant CALM_TICKS    = 20;    // ~0.2% price move
    uint256 public constant FULL_TICKS    = 200;   // ~2% price move
    uint256 public constant ANCHOR_PERIOD = 300;

    /// @dev Transient slot: total fee charged in the current swap's beforeSwap
    uint256 private constant PRE_FEE_SLOT = 0x8220d9fd2a41b0490df757cb156304643f600ab795f335b730e9bf367dd5c8bc;

    // Immutable

    IPoolManager public immutable poolManager;

    // Access control state

    address public immutable signerA;
    address public immutable signerB;
    address public treasury;

    // 2-of-2 multisig

    struct PendingAction {
        address proposer;
        uint256 proposedAt;
        uint256 confirmedAt; // 0 until both signers have confirmed
    }

    mapping(bytes32 => PendingAction) public pendingActions;
    uint256 public constant TIMELOCK = 15 minutes;
    uint256 public constant CONFIRM_WINDOW = 30 minutes;
    uint256 public constant EXECUTE_WINDOW = 30 minutes;

    // Pool state

    struct PoolState {
        int24  anchorTick;
        uint40 lastAnchorUpdate;
    }

    mapping(PoolId => PoolState) internal _states;

    // Events

    event FeeCharged(PoolId indexed poolId, uint24 totalFee, uint256 treasuryAmount, uint256 lpTopUpAmount);
    event TreasurySwept(Currency indexed currency, address indexed treasury, uint256 amount);

    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

    error NotProposedYet();
    error TimelockNotElapsed();
    error AlreadyConfirmed();
    error ProposalExpired();

    // Modifiers

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not PoolManager");
        _;
    }

    modifier onlyMultisig() {
        require(msg.sender == signerA || msg.sender == signerB, "not a signer");
        _;
    }

    // Constructor

    constructor(IPoolManager _poolManager, address _signerA, address _signerB, address _treasury) {
        require(_signerA != _signerB && _signerA != address(0) && _signerB != address(0), "bad signers");
        require(_treasury != address(0), "zero treasury");

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        poolManager = _poolManager;
        signerA     = _signerA;
        signerB     = _signerB;
        treasury    = _treasury;
    }

    // Treasury

    function proposeSetTreasury(address newTreasury) external onlyMultisig returns (bytes32) {
        require(newTreasury != address(0), "zero address");
        bytes32 actionHash = keccak256(abi.encode("setTreasury", newTreasury));
        pendingActions[actionHash] = PendingAction(msg.sender, block.timestamp, 0);
        return actionHash;
    }

    /// @notice First call by the other signer starts the timelock, a second call after it executes
    function confirmAndExecuteSetTreasury(address newTreasury) external onlyMultisig {
        bytes32 actionHash = keccak256(abi.encode("setTreasury", newTreasury));
        PendingAction storage action = pendingActions[actionHash];
        if (action.proposer == address(0)) revert NotProposedYet();
        if (action.proposer == msg.sender) revert AlreadyConfirmed();

        if (action.confirmedAt == 0) {
            if (block.timestamp > action.proposedAt + CONFIRM_WINDOW) revert ProposalExpired();
            action.confirmedAt = block.timestamp;
            return;
        }
        if (block.timestamp < action.confirmedAt + TIMELOCK) revert TimelockNotElapsed();
        if (block.timestamp > action.confirmedAt + TIMELOCK + EXECUTE_WINDOW) revert ProposalExpired();

        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
        delete pendingActions[actionHash];
    }

    /// @notice Sends a treasury share that failed to transfer during a swap. Callable by anyone.
    function sweepToTreasury(Currency currency) external {
        uint256 amount = poolManager.balanceOf(address(this), currency.toId());
        if (amount == 0) return;
        poolManager.unlock(abi.encode(currency, amount));
        emit TreasurySwept(currency, treasury, amount);
    }

    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, treasury, amount);
        return "";
    }

    // View helpers

    /// @notice Total fee (pips) for a given distance from the anchor. Always within [MIN_FEE, MAX_FEE].
    function feeForDeviation(uint256 deviation) public pure returns (uint24) {
        if (deviation <= CALM_TICKS) return MIN_FEE;
        if (deviation >= FULL_TICKS) return MAX_FEE;
        return uint24(MIN_FEE + (uint256(MAX_FEE - MIN_FEE) * (deviation - CALM_TICKS)) / (FULL_TICKS - CALM_TICKS));
    }

    function getPoolState(PoolId id) external view returns (PoolState memory) {
        return _states[id];
    }

    // Hook permissions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:              true,
            afterInitialize:               true,
            beforeAddLiquidity:            false,
            afterAddLiquidity:             false,
            beforeRemoveLiquidity:         false,
            afterRemoveLiquidity:          false,
            beforeSwap:                    true,
            afterSwap:                     true,
            beforeDonate:                  false,
            afterDonate:                   false,
            beforeSwapReturnDelta:         false,
            afterSwapReturnDelta:          true,
            afterAddLiquidityReturnDelta:  false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Hook lifecycle

    /// @dev Static-fee pools ignore the hook's fee, which would bypass MAX_FEE
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external view override onlyPoolManager returns (bytes4)
    {
        require(key.fee.isDynamicFee(), "dynamic fee only");
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external override onlyPoolManager returns (bytes4) {
        PoolState storage state = _states[key.toId()];
        state.anchorTick       = tick;
        state.lastAnchorUpdate = uint40(block.timestamp);
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

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        _updateAnchor(state, currentTick);

        uint24 fee = feeForDeviation(_deviation(currentTick, state.anchorTick));
        assembly ("memory-safe") {
            tstore(PRE_FEE_SLOT, fee)
        }

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            _lpShare(fee) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();

        uint24 preFee;
        assembly ("memory-safe") {
            preFee := tload(PRE_FEE_SLOT)
        }
        uint24 totalFee = _totalFee(poolId, preFee);

        // The hook can only take the unspecified currency
        bool specifiedIsZero = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = specifiedIsZero ? delta.amount1() : delta.amount0();
        uint256 base = uint256(uint128(unspecified < 0 ? -unspecified : unspecified));

        uint256 treasuryAmount = (base * (totalFee - _lpShare(totalFee))) / PIPS_DENOMINATOR;
        uint256 topUpAmount    = (base * (_lpShare(totalFee) - _lpShare(preFee))) / PIPS_DENOMINATOR;

        // Donating to a pool with no active liquidity reverts
        if (topUpAmount != 0 && poolManager.getLiquidity(poolId) == 0) topUpAmount = 0;

        _collect(key, specifiedIsZero, treasuryAmount, topUpAmount);

        emit FeeCharged(poolId, totalFee, treasuryAmount, topUpAmount);

        return (IHooks.afterSwap.selector, int128(int256(treasuryAmount + topUpAmount)));
    }

    // Internal

    /// @dev Moves the anchor towards the tick by the elapsed share of ANCHOR_PERIOD. Elapsed time
    ///      is kept until it produces a step, otherwise rounding would let dust swaps freeze the anchor.
    function _updateAnchor(PoolState storage state, int24 currentTick) internal {
        uint256 elapsed = block.timestamp - state.lastAnchorUpdate;
        if (elapsed == 0) return;

        int256 gap = int256(currentTick) - int256(state.anchorTick);
        int256 step = elapsed >= ANCHOR_PERIOD ? gap : (gap * int256(elapsed)) / int256(ANCHOR_PERIOD);

        // A zero gap also restarts the clock: idle time must not count towards the next move
        if (step == 0 && gap != 0) return;

        state.anchorTick       = state.anchorTick + int24(step);
        state.lastAnchorUpdate = uint40(block.timestamp);
    }

    /// @dev The higher of the fee charged before the swap and the fee for the post-swap tick
    function _totalFee(PoolId poolId, uint24 preFee) internal view returns (uint24) {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint24 postFee = feeForDeviation(_deviation(currentTick, _states[poolId].anchorTick));
        return postFee > preFee ? postFee : preFee;
    }

    function _collect(PoolKey calldata key, bool specifiedIsZero, uint256 treasuryAmount, uint256 topUpAmount) internal {
        Currency currency = specifiedIsZero ? key.currency1 : key.currency0;
        if (treasuryAmount != 0) {
            try poolManager.take(currency, treasury, treasuryAmount) {} catch {
                poolManager.mint(address(this), currency.toId(), treasuryAmount);
            }
        }
        if (topUpAmount != 0) {
            specifiedIsZero
                ? poolManager.donate(key, 0, topUpAmount, "")
                : poolManager.donate(key, topUpAmount, 0, "");
        }
    }

    function _deviation(int24 tick, int24 anchor) internal pure returns (uint256) {
        int256 gap = int256(tick) - int256(anchor);
        return uint256(gap < 0 ? -gap : gap);
    }

    function _lpShare(uint24 fee) internal pure returns (uint24) {
        return fee - uint24((uint256(fee) * TREASURY_BPS) / BPS_DENOMINATOR);
    }

    // IHooks stubs

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

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return IHooks.afterDonate.selector; }
}

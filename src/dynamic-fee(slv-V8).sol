// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

interface IPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title VolatilityGuardHookV8
/// @notice The swap fee scales linearly from 0.01% to 2% with the distance between the pool tick
///         and a time-weighted anchor tick. 90% of it goes to the pool's LPs, 10% to the treasury.
///
/// Fee model:
///   - deviation <= CALM_TICKS -> MIN_FEE, deviation >= FULL_TICKS -> MAX_FEE, linear in between
///   - beforeSwap charges the fee for the pre-swap tick
///   - afterSwap tops it up if the swap's own price move earned a higher fee
///   - the anchor follows the tick by time only, so splitting a move into many swaps
///     or sending dust swaps cannot move it faster or hold the fee up
///
/// Pools: any dynamic-fee pool whose currency0 is native ETH can use the hook, so the treasury
/// share is always taken in ETH.
///
/// Fee split:
///   - LP_BPS (90%) is the pool's LP fee: it accrues in the positions and is paid out together
///     with the liquidity when a position is decreased or closed
///   - TREASURY_BPS (10%) is taken in ETH and accrues in the hook as ERC-6909 claims of all pools
///     together. Once the claims exceed PAYOUT_USD worth of ETH they are sent to the treasury in
///     the same swap. The threshold in ETH is refreshed from Chainlink at each payout
///   - when ETH is the specified side of a swap, the treasury share can only be taken in beforeSwap,
///     at the pre-swap fee. The top-up for the swap's own price move then comes in the other token
///     and goes to the LPs in full
///
/// Limits:
///   - all fee parameters and the treasury address are fixed at deployment
///   - there is no owner or admin: nobody can change fees, pause swaps or touch liquidity
///   - a treasury that cannot receive ETH never blocks swaps, the claims just keep accruing
///   - a Uniswap protocol fee (max 0.1%), if governance enables it, is charged on top
contract VolatilityGuardHookV8 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary  for IPoolManager;
    using LPFeeLibrary  for uint24;

    // Fee limits (pips, 1e6 = 100%)

    uint24  public constant MIN_FEE = 100;     // 0.01%
    uint24  public constant MAX_FEE = 20_000;  // 2.00%

    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant PIPS_DENOMINATOR = 1_000_000;
    uint256 public constant LP_BPS           = 9_000; // 90% of the fee
    uint256 public constant TREASURY_BPS     = 1_000; // 10% of the fee, in ETH

    uint256 public constant CALM_TICKS    = 20;    // ~0.2% price move
    uint256 public constant FULL_TICKS    = 200;   // ~2% price move
    uint256 public constant ANCHOR_PERIOD = 300;

    /// @notice Minimum accrued treasury share for a payout, USD with the feed's 8 decimals
    uint256 public constant PAYOUT_USD = 100e8;

    /// @dev ERC-6909 id of native ETH in the PoolManager
    uint256 private constant ETH_ID = 0;

    /// @dev Transient slot: fee computed in the current swap's beforeSwap
    uint256 private constant PRE_FEE_SLOT = 0x8220d9fd2a41b0490df757cb156304643f600ab795f335b730e9bf367dd5c8bc;

    // Immutable

    IPoolManager public immutable poolManager;
    address      public immutable treasury;
    IPriceFeed   public immutable ethUsdFeed;

    // State

    struct PoolState {
        int24  anchorTick;
        uint40 lastAnchorUpdate;
    }

    mapping(PoolId => PoolState) internal _states;

    /// @notice Accrued ETH (wei) above which the next swap pays the treasury
    uint256 public payoutThreshold;

    event TreasuryPaid(uint256 amount, uint256 nextThreshold);

    error NotPoolManager();
    error UnsupportedPool();
    error BadConfig();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _treasury, IPriceFeed _ethUsdFeed) {
        if (_treasury == address(0)) revert BadConfig();
        (, int256 answer,,,) = _ethUsdFeed.latestRoundData();
        if (answer <= 0) revert BadConfig();

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        poolManager     = _poolManager;
        treasury        = _treasury;
        ethUsdFeed      = _ethUsdFeed;
        payoutThreshold = (PAYOUT_USD * 1e18) / uint256(answer);
    }

    // Views

    /// @notice Fee (pips) for a given distance from the anchor. Always within [MIN_FEE, MAX_FEE].
    function feeForDeviation(uint256 deviation) public pure returns (uint24) {
        if (deviation <= CALM_TICKS) return MIN_FEE;
        if (deviation >= FULL_TICKS) return MAX_FEE;
        unchecked {
            return uint24(MIN_FEE + (uint256(MAX_FEE - MIN_FEE) * (deviation - CALM_TICKS)) / (FULL_TICKS - CALM_TICKS));
        }
    }

    /// @notice Fee for the current tick against the stored anchor, before any time-based update
    function currentFee(PoolId id) external view returns (uint24) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        return feeForDeviation(_deviation(tick, _states[id].anchorTick));
    }

    function getPoolState(PoolId id) external view returns (PoolState memory) {
        return _states[id];
    }

    /// @notice Treasury share accrued in the hook and not paid out yet, wei
    function accruedTreasury() external view returns (uint256) {
        return poolManager.balanceOf(address(this), ETH_ID);
    }

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
            beforeSwapReturnDelta:         true,
            afterSwapReturnDelta:          true,
            afterAddLiquidityReturnDelta:  false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Hook callbacks

    /// @dev Static-fee pools ignore the hook's fee, and the treasury share is only taken in ETH
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external view onlyPoolManager returns (bytes4)
    {
        if (!key.fee.isDynamicFee() || !key.currency0.isAddressZero()) revert UnsupportedPool();
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external onlyPoolManager returns (bytes4)
    {
        _states[key.toId()] = PoolState(tick, uint40(block.timestamp));
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolState storage state = _states[poolId];

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        _updateAnchor(state, currentTick);

        uint24 fee = feeForDeviation(_deviation(currentTick, state.anchorTick));
        assembly ("memory-safe") {
            tstore(PRE_FEE_SLOT, fee)
        }

        // ETH (currency0) is the specified side: only here can the treasury share be taken in ETH
        int128 treasuryTake;
        if ((params.amountSpecified < 0) == params.zeroForOne) {
            int256 s = params.amountSpecified;
            uint256 amount = uint256(s < 0 ? -s : s);
            uint256 t = (amount * _share(fee, TREASURY_BPS)) / PIPS_DENOMINATOR;
            if (t != 0) {
                poolManager.mint(address(this), ETH_ID, t);
                treasuryTake = int128(int256(t));
            }
        }

        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(treasuryTake, 0),
            _share(fee, LP_BPS) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();

        uint24 preFee;
        assembly ("memory-safe") {
            preFee := tload(PRE_FEE_SLOT)
        }
        uint24 totalFee = _totalFee(poolId, preFee);

        // The hook can only take the unspecified currency here
        bool ethSpecified = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = ethSpecified ? delta.amount1() : delta.amount0();
        uint256 base = uint256(uint128(unspecified < 0 ? -unspecified : unspecified));

        uint256 charged = _charge(key, ethSpecified, base, totalFee, preFee);
        _maybePayout();
        return (IHooks.afterSwap.selector, int128(int256(charged)));
    }

    // Internal

    /// @dev LP top-up for the swap's own price move and, when ETH is unspecified, the treasury share.
    ///      Both come from the unspecified currency. Returns the total amount taken.
    function _charge(PoolKey calldata key, bool ethSpecified, uint256 base, uint24 totalFee, uint24 preFee)
        internal
        returns (uint256)
    {
        PoolId poolId = key.toId();
        // With ETH specified the treasury share was fixed in beforeSwap, so the LPs get the whole
        // top-up. Otherwise they get their 90% of it and the treasury its 10% below.
        uint256 topUp = ethSpecified
            ? (base * (totalFee - preFee)) / PIPS_DENOMINATOR
            : (base * (_share(totalFee, LP_BPS) - _share(preFee, LP_BPS))) / PIPS_DENOMINATOR;
        // Donating to a pool with no active liquidity reverts
        if (topUp != 0 && poolManager.getLiquidity(poolId) == 0) topUp = 0;
        if (topUp != 0) {
            ethSpecified ? poolManager.donate(key, 0, topUp, "") : poolManager.donate(key, topUp, 0, "");
        }

        uint256 t;
        if (!ethSpecified) {
            t = (base * _share(totalFee, TREASURY_BPS)) / PIPS_DENOMINATOR;
            if (t != 0) poolManager.mint(address(this), ETH_ID, t);
        }
        return topUp + t;
    }

    /// @dev Pays all but 1 wei of the claims once they pass the threshold. Keeping 1 wei leaves the
    ///      claims slot non-zero, so the next accrual is not charged a fresh storage write.
    ///      Runs last in afterSwap: the transfer can run treasury code.
    function _maybePayout() internal {
        uint256 accrued = poolManager.balanceOf(address(this), ETH_ID);
        if (accrued <= payoutThreshold) return;
        uint256 amount;
        unchecked { amount = accrued - 1; }

        try poolManager.take(CurrencyLibrary.ADDRESS_ZERO, treasury, amount) {
            poolManager.burn(address(this), ETH_ID, amount);
        } catch {
            return; // the treasury rejected ETH: keep accruing, swaps go on
        }

        uint256 next = payoutThreshold;
        try ethUsdFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            if (answer > 0) next = (PAYOUT_USD * 1e18) / uint256(answer);
        } catch {}
        payoutThreshold = next;
        emit TreasuryPaid(amount, next);
    }

    /// @dev The higher of the fee charged before the swap and the fee for the post-swap tick
    function _totalFee(PoolId poolId, uint24 preFee) internal view returns (uint24) {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint24 postFee = feeForDeviation(_deviation(currentTick, _states[poolId].anchorTick));
        return postFee > preFee ? postFee : preFee;
    }

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

    function _deviation(int24 tick, int24 anchor) internal pure returns (uint256) {
        int256 gap = int256(tick) - int256(anchor);
        return uint256(gap < 0 ? -gap : gap);
    }

    function _share(uint24 fee, uint256 bps) internal pure returns (uint24) {
        unchecked { return uint24((uint256(fee) * bps) / BPS_DENOMINATOR); }
    }
}

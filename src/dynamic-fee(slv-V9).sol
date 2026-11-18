// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title VolatilityGuardHookV9
/// @notice VolatilityGuardHookV8 plus market-price protection for pool creation and deposits.
///
/// Price protection:
///   - tokens with a Chainlink price (set at deployment, see `oracles`): anyone can create a native ETH
///     pool, but only at a price within ORACLE_TOLERANCE of Chainlink. WETH pools: only the initializer,
///     and still only at the oracle price. Liquidity can only be added while
///     the pool price is within the same tolerance. An empty pool off the oracle price is moved to
///     it for free on the next deposit, or by anyone through `alignToOracle`
///   - a feed that has been silent for FEED_DEAD_AFTER, reverts or is gone counts as shut down: its token
///     then follows the no-oracle rule below until the feed answers again. A shorter outage pauses
///     pool creation and deposits for that token
///   - tokens without a Chainlink price: only the trusted `initializer` (checked as tx.origin, so the
///     Uniswap interface works) can create a pool or add liquidity to a pool with no active
///     liquidity. Anyone can add to a pool that already has active liquidity
///   - removing liquidity and collecting fees are never checked
///
/// Fees:
///   Each token has a base (calm) fee: set at deployment or added later by the initializer, never
///   changed or removed once set. A token without one pays DEFAULT_BASE_FEE (1%). The swap fee scales
///   linearly from the pool's base fee to MAX_FEE (2%) with the distance between the pool tick and a
///   time-weighted anchor tick. 90% of it goes to the pool's LPs, 10% to the treasury.
///
/// Fee model:
///   - deviation <= CALM_TICKS -> base fee, deviation >= FULL_TICKS -> MAX_FEE, linear in between
///   - beforeSwap charges the fee for the pre-swap tick
///   - afterSwap tops it up if the swap's own price move earned a higher fee
///   - the anchor follows the tick by time only, so splitting a move into many swaps
///     or sending dust swaps cannot move it faster or hold the fee up
///
/// Pools: dynamic-fee pools of a token against native ETH (always currency0), or against WETH (either
/// side, by address order). WETH pools can only be created by the initializer. The treasury share is
/// taken in the pool's ETH side: native ETH or WETH, each accrued and paid out separately.
///
/// Fee split:
///   - LP_BPS (90%) is the pool's LP fee: it accrues in the positions and is paid out together
///     with the liquidity when a position is decreased or closed
///   - TREASURY_BPS (10%) is taken in the pool's ETH side and accrues in the hook as ERC-6909 claims of
///     all pools together, native ETH and WETH apart. Once either balance exceeds PAYOUT_USD worth of
///     ETH it is sent to the treasury in the same swap. The threshold in ETH is refreshed from
///     Chainlink at each payout
///   - when ETH is the specified side of a swap, the treasury share can only be taken in beforeSwap,
///     at the pre-swap fee. The top-up for the swap's own price move then comes in the other token
///     and goes to the LPs in full
///
/// Limits:
///   - the fee curve, the treasury address and the oracle routes are fixed at deployment
///   - the only admin action is `setBaseFee` by the initializer, for a token that has no base fee yet:
///     the list can only grow. Nobody can change a set fee, pause swaps or touch liquidity
///   - a treasury that cannot receive ETH never blocks swaps, the claims just keep accruing
///   - a Uniswap protocol fee (max 0.1%), if governance enables it, is charged on top
contract VolatilityGuardHookV9 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary  for IPoolManager;
    using LPFeeLibrary  for uint24;

    // Market-price protection

    /// @notice Allowed distance between the pool price and the oracle price: 3% in price.
    ///         Compared on sqrt prices: sqrt(0.97) and sqrt(1.03), scaled by 1e6
    uint256 public constant ORACLE_TOLERANCE_BPS = 300;
    uint256 private constant SQRT_LOW_E6  = 984_886;
    uint256 private constant SQRT_HIGH_E6 = 1_014_889;

    /// @notice Oldest acceptable ETH/USD answer, seconds (the feed's heartbeat is 1 hour)
    uint256 public constant ETH_USD_MAX_AGE = 7200;

    /// @notice A feed silent for this long, reverting or gone is treated as shut down: its token then
    ///         follows the no-oracle rule (trusted initializer) until the feed answers again.
    ///         Between maxAge and this, the feed counts as a temporary outage and the pair is paused
    uint256 public constant FEED_DEAD_AFTER = 7 days;

    uint8 private constant LIVE  = 1;
    uint8 private constant STALE = 2;
    uint8 private constant DEAD  = 3;

    /// @notice Chainlink route to a token's price in ETH, fixed at deployment:
    ///         price = feed1 [* feed2] [/ ETH-USD]
    struct OracleConfig {
        address token;
        address feed1;     // token/ETH, token/USD or token/BTC
        uint32  maxAge1;   // seconds
        address feed2;     // optional second factor, e.g. BTC/USD for WBTC/BTC
        uint32  maxAge2;
        bool    usdQuoted; // the product is in USD: divide by ETH/USD
    }

    struct Oracle {
        address feed1;
        uint32  maxAge1;
        uint8   decimals1;
        uint8   tokenDecimals;
        bool    usdQuoted;
        address feed2;
        uint32  maxAge2;
        uint8   decimals2;
    }

    // Fee limits (pips, 1e6 = 100%)

    uint24  public constant MAX_FEE          = 20_000; // 2.00%: the fee for a big move, every pool
    uint24  public constant MIN_BASE_FEE     = 100;    // 0.01%: lowest allowed base fee
    uint24  public constant MAX_BASE_FEE     = 10_000; // 1.00%: highest allowed base fee
    uint24  public constant DEFAULT_BASE_FEE = 10_000; // 1.00%: tokens without a set base fee

    /// @notice A token's base (calm) fee in pips
    struct TokenFee {
        address token;
        uint24  fee;
    }

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

    /// @dev Transient slot: the fee computed in the current swap's beforeSwap (low 32 bits) and the
    ///      pool's base fee (next 32 bits)
    uint256 private constant PRE_FEE_SLOT = 0x8220d9fd2a41b0490df757cb156304643f600ab795f335b730e9bf367dd5c8bc;

    // Immutable

    IPoolManager public immutable poolManager;
    address      public immutable treasury;
    IPriceFeed   public immutable ethUsdFeed;
    /// @notice Wallet allowed to create pools for tokens without an oracle and WETH pools, and to
    ///         refill empty pools of tokens without an oracle
    address      public immutable initializer;
    /// @notice Wrapped ETH. Pools against it are allowed on either side; address(0) disables them
    address      public immutable weth;
    uint256      private immutable ethUsdUnit;

    // State

    struct PoolState {
        int24   anchorTick;
        uint40  lastAnchorUpdate;
        address token; // currency1, for views by pool id; same storage slot as the anchor
    }

    mapping(PoolId => PoolState) internal _states;

    /// @dev Base fee per token, 0 = not set (DEFAULT_BASE_FEE applies)
    mapping(address => uint24) internal _baseFees;

    /// @notice Chainlink route per token. Set in the constructor only
    mapping(address => Oracle) public oracles;

    /// @notice Accrued ETH (wei) above which the next swap pays the treasury
    uint256 public payoutThreshold;

    event TreasuryPaid(address indexed currency, uint256 amount, uint256 nextThreshold);
    event AlignedToOracle(PoolId indexed id, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96);
    event BaseFeeSet(address indexed token, uint24 fee);

    error NotPoolManager();
    error UnsupportedPool();
    error BadConfig();
    error UnauthorizedInitializer();
    error PriceOffOracle();
    error OracleUnavailable();
    error NoOracle();
    error BaseFeeAlreadySet();
    error BadBaseFee();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _treasury,
        IPriceFeed _ethUsdFeed,
        address _initializer,
        OracleConfig[] memory _oracles,
        TokenFee[] memory _fees,
        address _weth
    ) {
        if (_treasury == address(0) || _initializer == address(0)) revert BadConfig();
        (, int256 answer,,,) = _ethUsdFeed.latestRoundData();
        if (answer <= 0) revert BadConfig();

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        poolManager     = _poolManager;
        treasury        = _treasury;
        ethUsdFeed      = _ethUsdFeed;
        initializer     = _initializer;
        weth            = _weth;
        ethUsdUnit      = 10 ** _ethUsdFeed.decimals();
        payoutThreshold = (PAYOUT_USD * 1e18) / uint256(answer);

        for (uint256 i; i < _oracles.length; ++i) {
            OracleConfig memory c = _oracles[i];
            if (c.token == address(0) || c.feed1 == address(0) || oracles[c.token].feed1 != address(0)) revert BadConfig();
            Oracle memory o = Oracle({
                feed1: c.feed1,
                maxAge1: c.maxAge1,
                decimals1: IPriceFeed(c.feed1).decimals(),
                tokenDecimals: IERC20Decimals(c.token).decimals(),
                usdQuoted: c.usdQuoted,
                feed2: c.feed2,
                maxAge2: c.maxAge2,
                decimals2: c.feed2 == address(0) ? 0 : IPriceFeed(c.feed2).decimals()
            });
            oracles[c.token] = o;
            (, uint8 status) = _readOracle(o);
            if (status != LIVE) revert OracleUnavailable(); // every route must work at deployment
        }

        for (uint256 i; i < _fees.length; ++i) {
            _setBaseFee(_fees[i].token, _fees[i].fee);
        }
    }

    // Base fees

    /// @notice Sets the base fee of a token that has none yet. Only the initializer, as the direct
    ///         caller, so no contract it interacts with can call this on its behalf. The list only grows:
    ///         a set fee can never be changed or removed
    function setBaseFee(address token, uint24 fee) external {
        if (msg.sender != initializer) revert UnauthorizedInitializer();
        _setBaseFee(token, fee);
    }

    function _setBaseFee(address token, uint24 fee) internal {
        if (token == address(0) || fee < MIN_BASE_FEE || fee > MAX_BASE_FEE) revert BadBaseFee();
        if (_baseFees[token] != 0) revert BaseFeeAlreadySet();
        _baseFees[token] = fee;
        emit BaseFeeSet(token, fee);
    }

    /// @notice A token's base (calm) fee in pips: its set fee, or DEFAULT_BASE_FEE
    function baseFee(address token) public view returns (uint24) {
        uint24 fee = _baseFees[token];
        return fee == 0 ? DEFAULT_BASE_FEE : fee;
    }

    /// @notice True if the token has its own base fee (otherwise DEFAULT_BASE_FEE applies)
    function hasBaseFee(address token) external view returns (bool) {
        return _baseFees[token] != 0;
    }

    // Views

    /// @notice Fee (pips) for a given distance from the anchor in a pool with `base` as its base fee.
    ///         Always within [base, MAX_FEE].
    function feeForDeviation(uint24 base, uint256 deviation) public pure returns (uint24) {
        if (deviation <= CALM_TICKS) return base;
        if (deviation >= FULL_TICKS) return MAX_FEE;
        unchecked {
            return uint24(base + (uint256(MAX_FEE - base) * (deviation - CALM_TICKS)) / (FULL_TICKS - CALM_TICKS));
        }
    }

    /// @notice Fee the next swap starts at: the current tick against the anchor as that swap will
    ///         see it, after the time-based catch-up
    function currentFee(PoolId id) external view returns (uint24) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        PoolState memory state = _states[id];
        (int24 anchor,) = _nextAnchor(state, tick);
        return feeForDeviation(baseFee(state.token), _deviation(tick, anchor));
    }

    /// @notice Chainlink price of `token` as a pool sqrtPriceX96 (native ETH is currency0).
    ///         Reverts with NoOracle when the token has no feed or its feed is shut down
    function oracleSqrtPriceX96(address token) external view returns (uint160) {
        Oracle memory o = oracles[token];
        if (o.feed1 == address(0)) revert NoOracle();
        (uint160 price, uint8 status) = _readOracle(o);
        if (status == DEAD) revert NoOracle();
        if (status == STALE) revert OracleUnavailable();
        return price;
    }

    /// @notice 0: no oracle, 1: live, 2: temporary outage (creation and deposits paused),
    ///         3: shut down (the trusted-initializer rule applies)
    function oracleStatus(address token) external view returns (uint8 status) {
        Oracle memory o = oracles[token];
        if (o.feed1 == address(0)) return 0;
        (, status) = _readOracle(o);
    }

    function getPoolState(PoolId id) external view returns (PoolState memory) {
        return _states[id];
    }

    /// @notice Treasury share in native ETH accrued in the hook and not paid out yet, wei
    function accruedTreasury() external view returns (uint256) {
        return poolManager.balanceOf(address(this), ETH_ID);
    }

    /// @notice Treasury share in WETH accrued in the hook and not paid out yet, wei
    function accruedTreasuryWeth() external view returns (uint256) {
        return weth == address(0) ? 0 : poolManager.balanceOf(address(this), uint256(uint160(weth)));
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:              true,
            afterInitialize:               true,
            beforeAddLiquidity:            true,
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

    /// @dev Static-fee pools ignore the hook's fee, and the treasury share is only taken in the ETH side.
    ///      Native ETH pools of a token with an oracle can be created by anyone at the oracle price.
    ///      WETH pools and pools of tokens without an oracle only by the initializer, and a token with an
    ///      oracle is held to the oracle price even then
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external view onlyPoolManager returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert UnsupportedPool();
        bool native = key.currency0.isAddressZero();
        if (!native && !_isWethPool(key)) revert UnsupportedPool();
        if (!native && tx.origin != initializer) revert UnauthorizedInitializer();

        (bool ethIs0, address token) = _sides(key.currency0, key.currency1);
        (uint160 target, bool hasOracle) = _target(token, ethIs0);
        if (hasOracle) {
            if (!_nearOracle(sqrtPriceX96, target)) revert PriceOffOracle();
        } else if (tx.origin != initializer) {
            revert UnauthorizedInitializer();
        }
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Deposits only at a trusted price. Removals and fee collection never reach this hook
    function beforeAddLiquidity(address, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external onlyPoolManager returns (bytes4)
    {
        PoolId poolId = key.toId();
        (bool ethIs0, address token) = _sides(key.currency0, key.currency1);
        (uint160 target, bool hasOracle) = _target(token, ethIs0);
        if (!hasOracle) {
            // The price of an empty pool can be set by anyone with a swap: only the initializer refills it
            if (poolManager.getLiquidity(poolId) == 0 && tx.origin != initializer) revert UnauthorizedInitializer();
        } else {
            (uint160 price,,,) = poolManager.getSlot0(poolId);
            if (!_nearOracle(price, target)) {
                if (poolManager.getLiquidity(poolId) != 0) revert PriceOffOracle();
                _moveEmptyPool(key, poolId, price, target);
            }
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external onlyPoolManager returns (bytes4)
    {
        (, address token) = _sides(key.currency0, key.currency1);
        _states[key.toId()] = PoolState(tick, uint40(block.timestamp), token);
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolState storage state = _states[poolId];

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        _updateAnchor(state, currentTick);

        (, address token) = _sides(key.currency0, key.currency1);
        uint24 base = baseFee(token);
        uint24 fee = feeForDeviation(base, _deviation(currentTick, state.anchorTick));
        assembly ("memory-safe") {
            tstore(PRE_FEE_SLOT, or(fee, shl(32, base)))
        }

        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(_takeFromSpecified(key, params, fee), 0),
            _share(fee, LP_BPS) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev When the ETH side (native or WETH) is the specified currency, only beforeSwap can take the
    ///      treasury share in it: at the pre-swap fee, from the specified amount
    function _takeFromSpecified(PoolKey calldata key, IPoolManager.SwapParams calldata params, uint24 fee)
        internal
        returns (int128)
    {
        (bool ethIs0,) = _sides(key.currency0, key.currency1);
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIs0 != ethIs0) return 0;
        int256 s = params.amountSpecified;
        uint256 t = (uint256(s < 0 ? -s : s) * _share(fee, TREASURY_BPS)) / PIPS_DENOMINATOR;
        if (t == 0) return 0;
        poolManager.mint(address(this), _ethId(key, ethIs0), t);
        return int128(int256(t));
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        (uint24 preFee, uint24 totalFee) = _swapFees(key.toId());

        // The hook can only take the unspecified currency here
        (bool ethIs0,) = _sides(key.currency0, key.currency1);
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        uint256 charged =
            _charge(key, ethIs0, specifiedIs0, _unspecifiedAmount(delta, specifiedIs0), totalFee, preFee);
        _maybePayout(ethIs0 ? key.currency0 : key.currency1);
        return (IHooks.afterSwap.selector, int128(int256(charged)));
    }

    // Internal

    /// @dev The fee charged in beforeSwap and the swap's total fee (the higher of that and the fee for
    ///      the post-swap tick, from the pool's base fee stored next to it)
    function _swapFees(PoolId poolId) internal view returns (uint24 preFee, uint24 totalFee) {
        uint24 calm;
        assembly ("memory-safe") {
            let packed := tload(PRE_FEE_SLOT)
            preFee := and(packed, 0xffffffff)
            calm := and(shr(32, packed), 0xffffffff)
        }
        totalFee = _totalFee(poolId, preFee, calm);
    }

    function _unspecifiedAmount(BalanceDelta delta, bool specifiedIs0) internal pure returns (uint256) {
        int128 unspecified = specifiedIs0 ? delta.amount1() : delta.amount0();
        return uint256(uint128(unspecified < 0 ? -unspecified : unspecified));
    }

    /// @dev LP top-up for the swap's own price move and, when the ETH side is unspecified, the treasury
    ///      share. Both come from the unspecified currency. Returns the total amount taken.
    function _charge(
        PoolKey calldata key,
        bool ethIs0,
        bool specifiedIs0,
        uint256 base,
        uint24 totalFee,
        uint24 preFee
    ) internal returns (uint256) {
        bool ethSpecified = specifiedIs0 == ethIs0;
        // With the ETH side specified the treasury share was fixed in beforeSwap, so the LPs get the
        // whole top-up. Otherwise they get their 90% of it and the treasury its 10% below.
        uint256 topUp = ethSpecified
            ? (base * (totalFee - preFee)) / PIPS_DENOMINATOR
            : (base * (_share(totalFee, LP_BPS) - _share(preFee, LP_BPS))) / PIPS_DENOMINATOR;
        // Donating to a pool with no active liquidity reverts
        if (topUp != 0 && poolManager.getLiquidity(key.toId()) == 0) topUp = 0;
        if (topUp != 0) {
            specifiedIs0 ? poolManager.donate(key, 0, topUp, "") : poolManager.donate(key, topUp, 0, "");
        }

        uint256 t;
        if (!ethSpecified) {
            t = (base * _share(totalFee, TREASURY_BPS)) / PIPS_DENOMINATOR;
            if (t != 0) poolManager.mint(address(this), _ethId(key, ethIs0), t);
        }
        return topUp + t;
    }

    /// @dev Pays all but 1 wei of the claims in `currency` (native ETH or WETH) once they pass the
    ///      threshold. Keeping 1 wei leaves the claims slot non-zero, so the next accrual is not charged
    ///      a fresh storage write. Runs last in afterSwap: the transfer can run treasury code.
    function _maybePayout(Currency currency) internal {
        uint256 id = uint256(uint160(Currency.unwrap(currency)));
        uint256 accrued = poolManager.balanceOf(address(this), id);
        if (accrued <= payoutThreshold) return;
        uint256 amount;
        unchecked { amount = accrued - 1; }

        try poolManager.take(currency, treasury, amount) {
            poolManager.burn(address(this), id, amount);
        } catch {
            return; // the treasury rejected the transfer: keep accruing, swaps go on
        }

        uint256 next = payoutThreshold;
        try ethUsdFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            if (answer > 0) next = (PAYOUT_USD * 1e18) / uint256(answer);
        } catch {}
        payoutThreshold = next;
        emit TreasuryPaid(Currency.unwrap(currency), amount, next);
    }

    /// @dev True if one side of the pool is WETH (and WETH pools are enabled)
    function _isWethPool(PoolKey calldata key) internal view returns (bool) {
        address w = weth;
        return w != address(0) && (Currency.unwrap(key.currency0) == w || Currency.unwrap(key.currency1) == w);
    }

    /// @dev ethIs0: the ETH side (native ETH or WETH) is currency0. token: the other currency
    function _sides(Currency c0, Currency c1) internal view returns (bool ethIs0, address token) {
        address a0 = Currency.unwrap(c0);
        if (a0 == address(0) || a0 == weth) return (true, Currency.unwrap(c1));
        return (false, a0);
    }

    /// @dev ERC-6909 id of the pool's ETH side: 0 for native ETH, the WETH address otherwise
    function _ethId(PoolKey calldata key, bool ethIs0) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(ethIs0 ? key.currency0 : key.currency1)));
    }

    /// @dev The higher of the fee charged before the swap and the fee for the post-swap tick
    function _totalFee(PoolId poolId, uint24 preFee, uint24 base) internal view returns (uint24) {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint24 postFee = feeForDeviation(base, _deviation(currentTick, _states[poolId].anchorTick));
        return postFee > preFee ? postFee : preFee;
    }

    /// @dev Moves the anchor towards the tick by the elapsed share of ANCHOR_PERIOD. Elapsed time
    ///      is kept until it produces a step, otherwise rounding would let dust swaps freeze the anchor.
    function _updateAnchor(PoolState storage state, int24 currentTick) internal {
        (int24 anchor, bool moved) = _nextAnchor(state, currentTick);
        if (!moved) return;
        state.anchorTick       = anchor;
        state.lastAnchorUpdate = uint40(block.timestamp);
    }

    /// @dev The anchor after the time-based catch-up, and whether the clock restarts
    function _nextAnchor(PoolState memory state, int24 currentTick) internal view returns (int24, bool) {
        uint256 elapsed = block.timestamp - state.lastAnchorUpdate;
        if (elapsed == 0) return (state.anchorTick, false);

        int256 gap = int256(currentTick) - int256(state.anchorTick);
        int256 step = elapsed >= ANCHOR_PERIOD ? gap : (gap * int256(elapsed)) / int256(ANCHOR_PERIOD);

        // A zero gap also restarts the clock: idle time must not count towards the next move
        if (step == 0 && gap != 0) return (state.anchorTick, false);
        return (state.anchorTick + int24(step), true);
    }

    function _deviation(int24 tick, int24 anchor) internal pure returns (uint256) {
        int256 gap = int256(tick) - int256(anchor);
        return uint256(gap < 0 ? -gap : gap);
    }

    function _share(uint24 fee, uint256 bps) internal pure returns (uint24) {
        unchecked { return uint24((uint256(fee) * bps) / BPS_DENOMINATOR); }
    }

    // Market price

    /// @notice Moves an empty pool of an oracle token to the oracle price. Free: with no active
    ///         liquidity the swap only moves the price. Anyone can call it
    function alignToOracle(PoolKey calldata key) external {
        if (address(key.hooks) != address(this)) revert UnsupportedPool();
        poolManager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        PoolId poolId = key.toId();
        (bool ethIs0, address token) = _sides(key.currency0, key.currency1);
        (uint160 target, bool hasOracle) = _target(token, ethIs0);
        if (!hasOracle) revert NoOracle();
        if (poolManager.getLiquidity(poolId) != 0) revert PriceOffOracle();
        (uint160 price,,,) = poolManager.getSlot0(poolId);
        _moveEmptyPool(key, poolId, price, target);
        return "";
    }

    /// @dev The hook's own swap skips its callbacks. It must cost nothing: any liquidity on the way
    ///      (positions out of range) would make the hook owe tokens, so then the move is refused
    function _moveEmptyPool(PoolKey memory key, PoolId poolId, uint160 price, uint160 target) internal {
        if (price == target) return;
        BalanceDelta delta = poolManager.swap(key, IPoolManager.SwapParams(target < price, -1, target), "");
        (uint160 moved,,,) = poolManager.getSlot0(poolId);
        if (BalanceDelta.unwrap(delta) != 0 || moved != target) revert PriceOffOracle();
        emit AlignedToOracle(poolId, price, target);
    }

    function _nearOracle(uint160 price, uint160 target) internal pure returns (bool) {
        uint256 p = uint256(price) * 1e6;
        return p >= uint256(target) * SQRT_LOW_E6 && p <= uint256(target) * SQRT_HIGH_E6;
    }

    /// @dev The oracle price for `token` as this pool's sqrtPriceX96, or hasOracle = false when the token
    ///      has no feed or its feed is shut down. A temporary outage reverts: creation and deposits wait
    ///      for the feed. With the ETH side as currency1 (WETH above the token's address) the pool price
    ///      is ETH per token, the inverse of the oracle's orientation
    function _target(address token, bool ethIs0) internal view returns (uint160 price, bool hasOracle) {
        Oracle memory o = oracles[token];
        if (o.feed1 == address(0)) return (0, false);
        uint8 status;
        (price, status) = _readOracle(o);
        if (status == STALE) revert OracleUnavailable();
        hasOracle = status == LIVE;
        if (hasOracle && !ethIs0) price = uint160((uint256(1) << 192) / price);
    }

    /// @dev Token price in ETH (18 decimals) from Chainlink, as a pool sqrtPriceX96:
    ///      token units per wei = 10^tokenDecimals / priceE18. Any dead feed on the route makes it DEAD,
    ///      otherwise any stale one makes it STALE
    function _readOracle(Oracle memory o) internal view returns (uint160, uint8) {
        (uint256 a1, uint8 s1) = _answer(o.feed1, o.maxAge1);
        uint256 a2 = 1;
        uint8 s2 = LIVE;
        if (o.feed2 != address(0)) (a2, s2) = _answer(o.feed2, o.maxAge2);
        uint256 a3 = ethUsdUnit;
        uint8 s3 = LIVE;
        if (o.usdQuoted) (a3, s3) = _answer(address(ethUsdFeed), ETH_USD_MAX_AGE);

        if (s1 == DEAD || s2 == DEAD || s3 == DEAD) return (0, DEAD);
        if (s1 == STALE || s2 == STALE || s3 == STALE) return (0, STALE);

        uint256 price = (a1 * 1e18) / 10 ** o.decimals1;
        if (o.feed2 != address(0)) price = (price * a2) / 10 ** o.decimals2;
        if (o.usdQuoted) price = (price * ethUsdUnit) / a3;
        if (price == 0) return (0, STALE);
        return (uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(10 ** o.tokenDecimals, 1 << 192, price))), LIVE);
    }

    /// @dev A low-level call, so a feed that reverts or no longer has code reads as DEAD instead of
    ///      reverting the caller
    function _answer(address feed, uint256 maxAge) internal view returns (uint256, uint8) {
        (bool ok, bytes memory ret) = feed.staticcall(abi.encodeCall(IPriceFeed.latestRoundData, ()));
        if (!ok || ret.length < 160) return (0, DEAD);
        (, int256 answer,, uint256 updatedAt,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        uint256 age = updatedAt >= block.timestamp ? 0 : block.timestamp - updatedAt;
        if (age > FEED_DEAD_AFTER) return (0, DEAD);
        if (answer <= 0 || age > maxAge) return (0, STALE);
        return (uint256(answer), LIVE);
    }
}

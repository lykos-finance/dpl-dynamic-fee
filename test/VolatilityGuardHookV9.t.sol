// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {VolatilityGuardHookV9, IPriceFeed} from "../src/dynamic-fee(slv-V9).sol";

contract MockFeedV9 is IPriceFeed {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
        updatedAt = block.timestamp;
    }

    function set(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
    }

    bool public reverting;

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverting, "feed shut down");
        return (0, answer, 0, updatedAt, 0);
    }
}

contract VolatilityGuardHookV9Test is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    Currency constant ETH = CurrencyLibrary.ADDRESS_ZERO;
    address treasury = address(0xA3);
    address trusted = address(0x7157);
    address stranger = address(0xBAD);

    MockFeedV9 ethUsd;
    MockFeedV9 tokenEth; // oracle for currency1: price of 1 token in ETH
    VolatilityGuardHookV9 hook;

    PoolKey oracleKey;   // ETH / currency1, has an oracle
    PoolKey plainKey;    // ETH / currency0, no oracle

    IPoolManager.ModifyLiquidityParams wide = IPoolManager.ModifyLiquidityParams(-60000, 60000, 1000e18, 0);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        ethUsd = new MockFeedV9(3000e8, 8);
        tokenEth = new MockFeedV9(1e18, 18); // 1 token = 1 ETH: SQRT_PRICE_1_1

        VolatilityGuardHookV9.OracleConfig[] memory cfg = new VolatilityGuardHookV9.OracleConfig[](1);
        cfg[0] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency1), address(tokenEth), 1 days, address(0), 0, false);
        address at = address(uint160(0x4000 << 144) | FLAGS);
        deployCodeTo("dynamic-fee(slv-V9).sol:VolatilityGuardHookV9", abi.encode(manager, treasury, ethUsd, trusted, cfg, _fees(), address(0)), at);
        hook = VolatilityGuardHookV9(at);

        oracleKey = PoolKey(ETH, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        plainKey = PoolKey(ETH, currency0, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
    }

    // Helpers

    /// @dev currency1 (the oracle token) is a "major" at 0.05%; currency0 has no base fee (1% default)
    function _fees() internal view returns (VolatilityGuardHookV9.TokenFee[] memory f) {
        f = new VolatilityGuardHookV9.TokenFee[](1);
        f[0] = VolatilityGuardHookV9.TokenFee(Currency.unwrap(currency1), 500);
    }

    function _hookError(bytes4 callback, bytes4 err) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(err),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _init(PoolKey memory key, uint160 price, address origin) internal {
        vm.prank(address(this), origin);
        manager.initialize(key, price);
    }

    function _add(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory p, address origin) internal {
        vm.prank(address(this), origin);
        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(key, p, ZERO_BYTES);
    }

    function _price(PoolKey memory key) internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(key.toId());
    }

    // Pool creation

    function test_oracleToken_anyoneCreatesAtOraclePrice() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        assertEq(_price(oracleKey), SQRT_PRICE_1_1);
    }

    function test_oracleToken_createOffPriceReverts() public {
        // 5% off in price (sqrt * 1.025)
        uint160 off = uint160(uint256(SQRT_PRICE_1_1) * 1025 / 1000);
        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.PriceOffOracle.selector));
        _init(oracleKey, off, trusted); // not even the trusted wallet can list off-price
    }

    function test_oracleToken_createWithinToleranceOk() public {
        uint160 near = uint160(uint256(SQRT_PRICE_1_1) * 1010 / 1000); // ~2% in price
        _init(oracleKey, near, stranger);
    }

    function test_plainToken_onlyTrustedCreates() public {
        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.UnauthorizedInitializer.selector));
        _init(plainKey, SQRT_PRICE_1_1, stranger);
        _init(plainKey, SQRT_PRICE_1_1, trusted);
    }

    function test_staleOracleBlocksCreation() public {
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.OracleUnavailable.selector));
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
    }

    // Deposits

    function test_oracleToken_depositOffPriceReverts() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        _add(oracleKey, wide, stranger);
        tokenEth.set(1.1e18); // market moved 10%, the pool did not
        vm.expectRevert(_hookError(IHooks.beforeAddLiquidity.selector, VolatilityGuardHookV9.PriceOffOracle.selector));
        _add(oracleKey, wide, stranger);
        // Removing is never blocked
        modifyLiquidityRouter.modifyLiquidity(oracleKey, IPoolManager.ModifyLiquidityParams(-60000, 60000, -500e18, 0), ZERO_BYTES);
    }

    function test_oracleToken_emptyPoolAlignedOnDeposit() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        tokenEth.set(0.8e18); // token cheaper: more token units per ETH, higher sqrt price
        uint160 target = hook.oracleSqrtPriceX96(Currency.unwrap(currency1));
        assertGt(target, SQRT_PRICE_1_1);

        _add(oracleKey, wide, stranger);
        assertEq(_price(oracleKey), target, "deposit went in at the oracle price");
        assertGt(manager.getLiquidity(oracleKey.toId()), 0);
    }

    function test_alignToOracle_publicAndFree() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        tokenEth.set(1.25e18);
        uint160 target = hook.oracleSqrtPriceX96(Currency.unwrap(currency1));
        uint256 ethBefore = address(this).balance;
        vm.prank(stranger);
        hook.alignToOracle(oracleKey);
        assertEq(_price(oracleKey), target);
        assertEq(address(this).balance, ethBefore);
    }

    function test_alignRefusedWithLiquidityInTheWay() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        // Liquidity only above the current price: active liquidity is 0, but a move up would cross it
        _add(oracleKey, IPoolManager.ModifyLiquidityParams(600, 6000, 100e18, 0), stranger);
        assertEq(manager.getLiquidity(oracleKey.toId()), 0);
        tokenEth.set(0.5e18); // target far above: through the position
        vm.expectRevert(VolatilityGuardHookV9.PriceOffOracle.selector);
        hook.alignToOracle(oracleKey);
    }

    function test_alignToOracle_rejectsPoolWithLiquidity() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        _add(oracleKey, wide, stranger);
        tokenEth.set(1.2e18);
        vm.expectRevert(VolatilityGuardHookV9.PriceOffOracle.selector);
        hook.alignToOracle(oracleKey);
    }

    function test_staleOracleBlocksDepositNotRemoval() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        _add(oracleKey, wide, stranger);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(_hookError(IHooks.beforeAddLiquidity.selector, VolatilityGuardHookV9.OracleUnavailable.selector));
        _add(oracleKey, wide, stranger);
        modifyLiquidityRouter.modifyLiquidity(oracleKey, IPoolManager.ModifyLiquidityParams(-60000, 60000, -1000e18, 0), ZERO_BYTES);
    }

    function test_plainToken_emptyPoolOnlyTrustedRefills() public {
        _init(plainKey, SQRT_PRICE_1_1, trusted);
        vm.expectRevert(_hookError(IHooks.beforeAddLiquidity.selector, VolatilityGuardHookV9.UnauthorizedInitializer.selector));
        _add(plainKey, wide, stranger);
        _add(plainKey, wide, trusted);
        _add(plainKey, wide, stranger); // active liquidity now: anyone can add
    }

    // Swaps and fees stay as in V8

    function test_swapsChargeAndAccrueTreasury() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        _add(oracleKey, wide, stranger);
        swapRouter.swap{value: 1 ether}(
            oracleKey,
            IPoolManager.SwapParams(true, -1 ether, MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ZERO_BYTES
        );
        assertGt(hook.accruedTreasury(), 0);
    }

    function test_currentFee_includesAnchorCatchUp() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        _add(oracleKey, wide, stranger);
        // Big move: price far from the anchor
        swapRouter.swap{value: 100 ether}(
            oracleKey,
            IPoolManager.SwapParams(true, -100 ether, MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ZERO_BYTES
        );
        vm.warp(block.timestamp + 1);
        assertEq(hook.currentFee(oracleKey.toId()), hook.MAX_FEE());
        vm.warp(block.timestamp + hook.ANCHOR_PERIOD());
        assertEq(hook.currentFee(oracleKey.toId()), 500, "the next swap starts at the token's base fee");
    }

    // WETH pools

    function _hookWith(uint160 prefix, address w, VolatilityGuardHookV9.OracleConfig[] memory cfg)
        internal
        returns (VolatilityGuardHookV9)
    {
        address at = address(uint160(prefix << 144) | FLAGS);
        deployCodeTo(
            "dynamic-fee(slv-V9).sol:VolatilityGuardHookV9",
            abi.encode(manager, treasury, ethUsd, trusted, cfg, new VolatilityGuardHookV9.TokenFee[](0), w),
            at
        );
        return VolatilityGuardHookV9(at);
    }

    function _wethKey(VolatilityGuardHookV9 h) internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(h)));
    }

    function _swapErc20(PoolKey memory key, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            IPoolManager.SwapParams(zeroForOne, amount, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ZERO_BYTES
        );
    }

    function test_weth_onlyInitializerCreates_treasuryInWeth() public {
        // currency1 plays WETH: the ETH side is currency1
        VolatilityGuardHookV9 h = _hookWith(0x8000, Currency.unwrap(currency1), new VolatilityGuardHookV9.OracleConfig[](0));
        PoolKey memory key = _wethKey(h);

        vm.prank(address(this), stranger);
        vm.expectRevert(abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, address(h), IHooks.beforeInitialize.selector,
            abi.encodeWithSelector(VolatilityGuardHookV9.UnauthorizedInitializer.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        ));
        manager.initialize(key, SQRT_PRICE_1_1);

        _init(key, SQRT_PRICE_1_1, trusted);
        vm.prank(address(this), trusted);
        modifyLiquidityRouter.modifyLiquidity(key, wide, ZERO_BYTES);

        // Token in, WETH out: WETH unspecified, treasury share taken from the output in afterSwap
        _swapErc20(key, true, -1e15);
        uint256 afterFirst = h.accruedTreasuryWeth();
        assertGt(afterFirst, 0, "accrued in WETH");
        assertEq(h.accruedTreasury(), 0, "nothing in native ETH");
        assertEq(manager.balanceOf(address(h), currency0.toId()), 0, "never in the token");

        // WETH in, exact: WETH specified, treasury share taken from the input in beforeSwap, 10% of 1%
        _swapErc20(key, false, -1e15);
        assertEq(h.accruedTreasuryWeth() - afterFirst, (1e15 * 1_000) / 1e6);
    }

    function test_weth_payoutInWeth() public {
        VolatilityGuardHookV9 h = _hookWith(0x9000, Currency.unwrap(currency1), new VolatilityGuardHookV9.OracleConfig[](0));
        PoolKey memory key = _wethKey(h);
        _init(key, SQRT_PRICE_1_1, trusted);
        vm.prank(address(this), trusted);
        modifyLiquidityRouter.modifyLiquidity(key, wide, ZERO_BYTES);

        _swapErc20(key, true, -50e18); // big move: ~2% fee on the WETH output, 0.2% to the treasury
        assertGt(currency1.balanceOf(treasury), h.payoutThreshold() - 1, "treasury paid in WETH");
        assertEq(h.accruedTreasuryWeth(), 1, "1 wei kept");
    }

    function test_weth_asCurrency0_oracleCheckedEvenForInitializer() public {
        VolatilityGuardHookV9.OracleConfig[] memory cfg = new VolatilityGuardHookV9.OracleConfig[](1);
        cfg[0] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency1), address(tokenEth), 1 days, address(0), 0, false);
        VolatilityGuardHookV9 h = _hookWith(0xA000, Currency.unwrap(currency0), cfg); // currency0 plays WETH
        PoolKey memory key = _wethKey(h);

        vm.prank(address(this), stranger); // a stranger cannot create a WETH pool, even at the oracle price
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.prank(address(this), trusted); // the initializer cannot go off the oracle price
        vm.expectRevert();
        manager.initialize(key, uint160(uint256(SQRT_PRICE_1_1) * 1025 / 1000));
        _init(key, SQRT_PRICE_1_1, trusted);
        assertEq(_price(key), SQRT_PRICE_1_1);
    }

    function test_weth_asCurrency1_oraclePriceInverted() public {
        MockFeedV9 twoEth = new MockFeedV9(2e18, 18); // 1 token = 2 ETH
        VolatilityGuardHookV9.OracleConfig[] memory cfg = new VolatilityGuardHookV9.OracleConfig[](1);
        cfg[0] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency0), address(twoEth), 1 days, address(0), 0, false);
        VolatilityGuardHookV9 h = _hookWith(0xB000, Currency.unwrap(currency1), cfg); // currency1 plays WETH
        PoolKey memory key = _wethKey(h);

        // Pool price = WETH per token = 2, not the 0.5 tokens per ETH the oracle orientation gives
        uint160 two = uint160(_isqrt(uint256(2) << 192));
        vm.prank(address(this), trusted);
        vm.expectRevert();
        manager.initialize(key, uint160(_isqrt((uint256(1) << 192) / 2)));
        _init(key, two, trusted);

        // Deposits are checked against the same inverted price: a stranger can add at it
        vm.prank(address(this), stranger);
        modifyLiquidityRouter.modifyLiquidity(key, wide, ZERO_BYTES);
        twoEth.set(2.5e18); // the market moved 25%: deposits stop
        vm.prank(address(this), stranger);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(key, wide, ZERO_BYTES);
    }

    function test_noEthNoWeth_rejected() public {
        VolatilityGuardHookV9 h = _hookWith(0xC000, address(0x1234), new VolatilityGuardHookV9.OracleConfig[](0));
        vm.prank(address(this), trusted);
        vm.expectRevert();
        manager.initialize(_wethKey(h), SQRT_PRICE_1_1);
    }

    // Per-token base fees

    function test_baseFees_setDefaultAndCurve() public view {
        assertEq(hook.baseFee(Currency.unwrap(currency1)), 500, "set at deployment");
        assertEq(hook.baseFee(Currency.unwrap(currency0)), 10_000, "unlisted token: 1% default");
        assertTrue(hook.hasBaseFee(Currency.unwrap(currency1)));
        assertFalse(hook.hasBaseFee(Currency.unwrap(currency0)));
        // Curve from the base fee to the 2% cap
        assertEq(hook.feeForDeviation(500, 0), 500);
        assertEq(hook.feeForDeviation(500, 20), 500);
        assertEq(hook.feeForDeviation(500, 110), 500 + (19_500 * 90) / 180);
        assertEq(hook.feeForDeviation(500, 200), 20_000);
        assertEq(hook.feeForDeviation(10_000, 110), 15_000);
        assertEq(hook.feeForDeviation(2_500, type(uint256).max), 20_000);
    }

    function testFuzz_feeCurve_withinBaseAndCap(uint24 base, uint256 deviation) public view {
        base = uint24(bound(base, hook.MIN_BASE_FEE(), hook.MAX_BASE_FEE()));
        uint24 fee = hook.feeForDeviation(base, deviation);
        assertGe(fee, base);
        assertLe(fee, hook.MAX_FEE());
    }

    function test_setBaseFee_onlyInitializerOnlyOnce() public {
        address token = Currency.unwrap(currency0);
        vm.prank(stranger);
        vm.expectRevert(VolatilityGuardHookV9.UnauthorizedInitializer.selector);
        hook.setBaseFee(token, 2_500);

        // tx.origin is not enough: a contract the initializer calls cannot act for it
        vm.prank(stranger, trusted);
        vm.expectRevert(VolatilityGuardHookV9.UnauthorizedInitializer.selector);
        hook.setBaseFee(token, 2_500);

        vm.prank(trusted);
        vm.expectRevert(VolatilityGuardHookV9.BadBaseFee.selector);
        hook.setBaseFee(token, 10_001); // above 1%
        vm.prank(trusted);
        vm.expectRevert(VolatilityGuardHookV9.BadBaseFee.selector);
        hook.setBaseFee(token, 99); // below 0.01%

        vm.prank(trusted);
        hook.setBaseFee(token, 2_500);
        assertEq(hook.baseFee(token), 2_500);

        // The list only grows: no change, not even by the initializer
        vm.prank(trusted);
        vm.expectRevert(VolatilityGuardHookV9.BaseFeeAlreadySet.selector);
        hook.setBaseFee(token, 500);
        vm.prank(trusted);
        vm.expectRevert(VolatilityGuardHookV9.BaseFeeAlreadySet.selector);
        hook.setBaseFee(Currency.unwrap(currency1), 10_000); // set at deployment
    }

    function test_swapsChargeTheTokensBaseFee() public {
        // Major token (0.05%): a small calm swap pays 0.05%, of which the treasury gets 10% in ETH
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        _add(oracleKey, wide, stranger);
        swapRouter.swap{value: 1e15}(
            oracleKey, IPoolManager.SwapParams(true, -1e15, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ZERO_BYTES
        );
        assertEq(hook.accruedTreasury(), (1e15 * 50) / 1e6, "10% of 0.05% of the ETH input");

        // Unlisted token (1%): same swap, treasury share 20x larger
        _init(plainKey, SQRT_PRICE_1_1, trusted);
        _add(plainKey, wide, trusted);
        uint256 before = hook.accruedTreasury();
        swapRouter.swap{value: 1e15}(
            plainKey, IPoolManager.SwapParams(true, -1e15, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ZERO_BYTES
        );
        assertEq(hook.accruedTreasury() - before, (1e15 * 1_000) / 1e6, "10% of 1% of the ETH input");

        // Listing the token later lowers its pool's fee from the next swap on
        vm.prank(trusted);
        hook.setBaseFee(Currency.unwrap(currency0), 2_500);
        vm.warp(block.timestamp + 600);
        before = hook.accruedTreasury();
        swapRouter.swap{value: 1e15}(
            plainKey, IPoolManager.SwapParams(true, -1e15, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ZERO_BYTES
        );
        assertEq(hook.accruedTreasury() - before, (1e15 * 250) / 1e6, "10% of 0.25%");
    }

    // Config

    function test_constructorRejectsDeadFeed() public {
        MockFeedV9 dead = new MockFeedV9(0, 18);
        VolatilityGuardHookV9.OracleConfig[] memory cfg = new VolatilityGuardHookV9.OracleConfig[](1);
        cfg[0] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency1), address(dead), 1 days, address(0), 0, false);
        address at = address(uint160(0x5000 << 144) | FLAGS);
        vm.expectRevert(VolatilityGuardHookV9.OracleUnavailable.selector);
        deployCodeTo("dynamic-fee(slv-V9).sol:VolatilityGuardHookV9", abi.encode(manager, treasury, ethUsd, trusted, cfg, _fees(), address(0)), at);
    }

    function test_usdAndTwoFeedRoute() public {
        // token = 2 BTC-units: token/BTC 2.0 (8 dec) * BTC/USD 60000 (8 dec) / ETH/USD 3000 = 40 ETH
        MockFeedV9 tokBtc = new MockFeedV9(2e8, 8);
        MockFeedV9 btcUsd = new MockFeedV9(60000e8, 8);
        VolatilityGuardHookV9.OracleConfig[] memory cfg = new VolatilityGuardHookV9.OracleConfig[](1);
        cfg[0] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency0), address(tokBtc), 1 days, address(btcUsd), 1 hours, true);
        address at = address(uint160(0x6000 << 144) | FLAGS);
        deployCodeTo("dynamic-fee(slv-V9).sol:VolatilityGuardHookV9", abi.encode(manager, treasury, ethUsd, trusted, cfg, _fees(), address(0)), at);
        uint160 sp = VolatilityGuardHookV9(at).oracleSqrtPriceX96(Currency.unwrap(currency0));
        // 1 ETH = 1/40 token: price = 0.025 token units per wei (both 18 dec)
        uint256 priceE18 = uint256(sp) * uint256(sp) * 1e18 >> 192;
        assertApproxEqRel(priceE18, 0.025e18, 1e12);
    }


    /// Pool creation passes exactly when the start price is within 3% of the oracle price
    function testFuzz_toleranceBoundary(uint256 priceBps) public {
        priceBps = bound(priceBps, 9_000, 11_000);
        // Skip a thin band around the edges where rounding of the sqrt constants decides
        vm.assume(priceBps < 9_695 || priceBps > 9_705);
        vm.assume(priceBps < 10_295 || priceBps > 10_305);
        uint160 sp = uint160(_isqrt((uint256(1) << 192) * priceBps / 10_000));
        bool inside = priceBps >= 9_700 && priceBps <= 10_300;
        if (!inside) {
            vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.PriceOffOracle.selector));
        }
        _init(oracleKey, sp, stranger);
        if (inside) assertEq(_price(oracleKey), sp);
    }

    function _isqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // Dead-feed fallback

    function test_feedOutage_pausesThenDeadFeedFallsBackToInitializer() public {
        address token = Currency.unwrap(currency1);
        assertEq(hook.oracleStatus(token), 1, "live");
        assertEq(hook.oracleStatus(address(0xDEAD)), 0, "no oracle");

        vm.warp(block.timestamp + 3 days); // past maxAge (1 day), short of FEED_DEAD_AFTER
        assertEq(hook.oracleStatus(token), 2, "temporary outage");
        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.OracleUnavailable.selector));
        _init(oracleKey, SQRT_PRICE_1_1, trusted); // paused even for the initializer

        vm.warp(block.timestamp + 5 days); // 8 days silent: shut down
        assertEq(hook.oracleStatus(token), 3, "dead");
        vm.expectRevert(VolatilityGuardHookV9.NoOracle.selector);
        hook.oracleSqrtPriceX96(token);

        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.UnauthorizedInitializer.selector));
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        uint160 anyPrice = uint160(uint256(SQRT_PRICE_1_1) * 2); // no oracle to compare with any more
        _init(oracleKey, anyPrice, trusted);
        assertEq(_price(oracleKey), anyPrice);
    }

    function test_deadFeed_depositsFollowInitializerRule() public {
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
        _add(oracleKey, wide, stranger);
        PoolKey memory emptyKey = PoolKey(ETH, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        _init(emptyKey, SQRT_PRICE_1_1, stranger);

        vm.warp(block.timestamp + 8 days);
        _add(oracleKey, wide, stranger); // active liquidity: anyone, no price check
        vm.expectRevert(_hookError(IHooks.beforeAddLiquidity.selector, VolatilityGuardHookV9.UnauthorizedInitializer.selector));
        _add(emptyKey, IPoolManager.ModifyLiquidityParams(-60000, 60000, 1000e18, 0), stranger);
        _add(emptyKey, IPoolManager.ModifyLiquidityParams(-60000, 60000, 1000e18, 0), trusted);

        vm.expectRevert(VolatilityGuardHookV9.NoOracle.selector);
        hook.alignToOracle(emptyKey);
    }

    function test_revertingOrRemovedFeed_isDeadAtOnce() public {
        address token = Currency.unwrap(currency1);
        tokenEth.setReverting(true);
        assertEq(hook.oracleStatus(token), 3);
        _init(oracleKey, uint160(uint256(SQRT_PRICE_1_1) * 3), trusted);

        tokenEth.setReverting(false);
        vm.etch(address(tokenEth), ""); // the feed contract is gone
        assertEq(hook.oracleStatus(token), 3);
        vm.expectRevert(_hookError(IHooks.beforeAddLiquidity.selector, VolatilityGuardHookV9.UnauthorizedInitializer.selector));
        _add(oracleKey, wide, stranger);
    }

    function test_revivedFeed_restoresOracleRule() public {
        address token = Currency.unwrap(currency1);
        vm.warp(block.timestamp + 10 days);
        assertEq(hook.oracleStatus(token), 3);
        tokenEth.set(1e18); // Chainlink answers again
        assertEq(hook.oracleStatus(token), 1);

        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.PriceOffOracle.selector));
        _init(oracleKey, uint160(uint256(SQRT_PRICE_1_1) * 2), trusted);
        _init(oracleKey, SQRT_PRICE_1_1, stranger);
    }

    function test_deadEthUsd_deadForUsdRoutesOnly() public {
        MockFeedV9 tokBtc = new MockFeedV9(1e8, 8);
        MockFeedV9 btcUsd = new MockFeedV9(60000e8, 8);
        VolatilityGuardHookV9.OracleConfig[] memory cfg = new VolatilityGuardHookV9.OracleConfig[](2);
        cfg[0] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency0), address(tokBtc), 1 days, address(btcUsd), 1 hours, true);
        cfg[1] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency1), address(tokenEth), 1 days, address(0), 0, false);
        address at = address(uint160(0x7000 << 144) | FLAGS);
        deployCodeTo("dynamic-fee(slv-V9).sol:VolatilityGuardHookV9", abi.encode(manager, treasury, ethUsd, trusted, cfg, _fees(), address(0)), at);
        VolatilityGuardHookV9 h = VolatilityGuardHookV9(at);
        ethUsd.setReverting(true);
        assertEq(h.oracleStatus(Currency.unwrap(currency0)), 3, "USD route dead with ETH/USD");
        assertEq(h.oracleStatus(Currency.unwrap(currency1)), 1, "ETH route unaffected");
    }
}

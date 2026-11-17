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

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }
}

contract VolatilityGuardHookV9Test is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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
        deployCodeTo("dynamic-fee(slv-V9).sol:VolatilityGuardHookV9", abi.encode(manager, treasury, ethUsd, trusted, cfg), at);
        hook = VolatilityGuardHookV9(at);

        oracleKey = PoolKey(ETH, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        plainKey = PoolKey(ETH, currency0, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
    }

    // Helpers

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
        assertEq(hook.currentFee(oracleKey.toId()), hook.MIN_FEE(), "the next swap starts calm");
    }

    // Config

    function test_constructorRejectsDeadFeed() public {
        MockFeedV9 dead = new MockFeedV9(0, 18);
        VolatilityGuardHookV9.OracleConfig[] memory cfg = new VolatilityGuardHookV9.OracleConfig[](1);
        cfg[0] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency1), address(dead), 1 days, address(0), 0, false);
        address at = address(uint160(0x5000 << 144) | FLAGS);
        vm.expectRevert(VolatilityGuardHookV9.OracleUnavailable.selector);
        deployCodeTo("dynamic-fee(slv-V9).sol:VolatilityGuardHookV9", abi.encode(manager, treasury, ethUsd, trusted, cfg), at);
    }

    function test_usdAndTwoFeedRoute() public {
        // token = 2 BTC-units: token/BTC 2.0 (8 dec) * BTC/USD 60000 (8 dec) / ETH/USD 3000 = 40 ETH
        MockFeedV9 tokBtc = new MockFeedV9(2e8, 8);
        MockFeedV9 btcUsd = new MockFeedV9(60000e8, 8);
        VolatilityGuardHookV9.OracleConfig[] memory cfg = new VolatilityGuardHookV9.OracleConfig[](1);
        cfg[0] = VolatilityGuardHookV9.OracleConfig(Currency.unwrap(currency0), address(tokBtc), 1 days, address(btcUsd), 1 hours, true);
        address at = address(uint160(0x6000 << 144) | FLAGS);
        deployCodeTo("dynamic-fee(slv-V9).sol:VolatilityGuardHookV9", abi.encode(manager, treasury, ethUsd, trusted, cfg), at);
        uint160 sp = VolatilityGuardHookV9(at).oracleSqrtPriceX96(Currency.unwrap(currency0));
        // 1 ETH = 1/40 token: price = 0.025 token units per wei (both 18 dec)
        uint256 priceE18 = uint256(sp) * uint256(sp) * 1e18 >> 192;
        assertApproxEqRel(priceE18, 0.025e18, 1e12);
    }

}

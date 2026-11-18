// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DeployV9} from "../script/DeployV9(slv).s.sol";
import {PoolPriceAligner} from "../src/PoolPriceAligner.sol";
import {VolatilityGuardHookV9} from "../src/dynamic-fee(slv-V9).sol";

interface IERC20A {
    function approve(address, uint256) external returns (bool);
}

interface IPoolInitializer {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
}

/// @notice A scammer tries to get liquidity into V9 pools at a wrong price. Mainnet fork, real Chainlink
///         feeds and real Uniswap contracts; nothing is sent to mainnet. Amounts are valued at the
///         Chainlink price in USDC units (6 decimals).
contract VolatilityGuardHookV9AttackTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant VJDX = 0x47D8982457d52d3d59B87fE4913a07dEb764c4e5;

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    int24 constant LO = -887220;
    int24 constant HI = 887220;

    address owner = address(uint160(uint256(keccak256("atk owner"))));
    address scammer = address(uint160(uint256(keccak256("atk scammer"))));
    address victim = address(uint160(uint256(keccak256("atk victim"))));
    address honestLp = address(uint160(uint256(keccak256("atk honest lp"))));

    VolatilityGuardHookV9 hook;
    PoolModifyLiquidityTest lp;
    PoolSwapTest swapper;
    uint160 fair; // Chainlink ETH/USDC as sqrtPriceX96

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        address at = address((uint160(uint256(keccak256("atk hook"))) & ~uint160(0x3FFF)) | FLAGS);
        deployCodeTo(
            "dynamic-fee(slv-V9).sol:VolatilityGuardHookV9",
            abi.encode(PM, address(0x7EA5), ETH_USD, owner, new DeployV9().oracleList(), new DeployV9().feeList(), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            at
        );
        hook = VolatilityGuardHookV9(at);
        lp = new PoolModifyLiquidityTest(PM);
        swapper = new PoolSwapTest(PM);
        fair = hook.oracleSqrtPriceX96(USDC);
        address[4] memory people = [owner, scammer, victim, honestLp];
        for (uint256 i; i < 4; ++i) {
            vm.deal(people[i], 1_000 ether);
            deal(USDC, people[i], 10_000_000e6);
            vm.startPrank(people[i]);
            IERC20A(USDC).approve(address(lp), type(uint256).max);
            IERC20A(USDC).approve(address(swapper), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ── 1. Create ETH/USDC at half the ETH price, straight through the PoolManager ──
    function test_attack1_directInitAtWrongPrice() public {
        PoolKey memory key = _key(USDC, 60);
        uint160 half = _scale(fair, 7071, 10000); // sqrt(0.5): ETH priced at 50%
        vm.prank(scammer, scammer);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.PriceOffOracle.selector));
        PM.initialize(key, half);
        assertEq(_price(key), 0);
        console.log("1. direct initialize at -50%: REVERTED PriceOffOracle, pool not created");
    }

    // ── 2. Same through the Uniswap interface path (PositionManager.initializePool) ──
    function test_attack2_uiInitAtWrongPrice() public {
        PoolKey memory key = _key(USDC, 60);
        vm.prank(scammer, scammer);
        int24 tick = IPoolInitializer(POSM).initializePool(key, _scale(fair, 12247, 10000)); // ETH at +50%
        assertEq(tick, type(int24).max, "PositionManager swallows the revert");
        assertEq(_price(key), 0);
        console.log("2. initializePool via PositionManager at +50%: hook rejected it, pool not created");
    }

    // ── 3. Create right at the edge of the tolerance and wait for a victim ──
    function test_attack3_edgeOfTolerance() public {
        PoolKey memory key = _key(USDC, 60);
        uint160 edge = _scale(fair, 10143, 10000); // ETH priced ~2.9% above Chainlink: allowed
        vm.prank(scammer, scammer);
        PM.initialize(key, edge);

        // The victim deposits ~$20k full range at the pool's price
        int256 liq = int256(uint256(_liqFor(edge, 5 ether)));
        vm.prank(victim, victim);
        BalanceDelta dIn = lp.modifyLiquidity{value: 10 ether}(key, IPoolManager.ModifyLiquidityParams(LO, HI, liq, 0), "");

        // The scammer arbitrages the pool back to Chainlink
        int256 scammerPnl = _swapTo(scammer, key, fair);

        // The victim leaves
        vm.prank(victim, victim);
        BalanceDelta dOut = lp.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(LO, HI, -liq, 0), "");
        int256 victimPnl = _value(dIn) + _value(dOut);

        console.log("3. pool created 2.9% off (inside tolerance), victim deposits ~$20k:");
        _logUsd("   scammer P&L, USD", scammerPnl);
        _logUsd("   victim  P&L, USD", victimPnl);
        _logUsd("   victim deposit, USD", -_value(dIn));
    }

    // ── 4. Create at the fair price, then move the EMPTY pool far off for free and wait ──
    function test_attack4_moveEmptyPoolThenWait() public {
        PoolKey memory key = _key(USDC, 60);
        vm.prank(scammer, scammer);
        PM.initialize(key, fair);
        PoolPriceAligner aligner = new PoolPriceAligner(PM);
        uint160 bad = _scale(fair, 14142, 10000); // ETH at 2x
        vm.prank(scammer);
        aligner.align{value: 1e12}(key, bad, 1e12);
        assertEq(_price(key), bad);

        // A victim deposits with liquidity sized at the bad price, generous maximums
        int256 liq = int256(uint256(_liqFor(bad, 1 ether)));
        vm.prank(victim, victim);
        BalanceDelta dIn = lp.modifyLiquidity{value: 10 ether}(key, IPoolManager.ModifyLiquidityParams(LO, HI, liq, 0), "");
        assertEq(_price(key), fair, "the hook moved the pool back to Chainlink before the deposit");

        int256 scammerPnl = _swapTo(scammer, key, bad); // try to profit by pushing it back up
        console.log("4. empty pool moved to 2x, victim deposits: hook re-aligned the pool to Chainlink first");
        _logUsd("   victim deposit value at Chainlink, USD", -_value(dIn));
        _logUsd("   scammer P&L pushing the price to 2x afterwards, USD", scammerPnl);
    }

    // ── 5. Dust liquidity so the pool is "not empty", then move the price far ──
    function test_attack5_dustThenMove() public {
        PoolKey memory key = _key(USDC, 60);
        vm.prank(scammer, scammer);
        PM.initialize(key, fair);
        vm.prank(scammer, scammer);
        lp.modifyLiquidity{value: 1 ether}(key, IPoolManager.ModifyLiquidityParams(LO, HI, 1e9, 0), "");
        int256 cost = _swapTo(scammer, key, _scale(fair, 14142, 10000)); // ETH at 2x through dust
        int256 liq = int256(uint256(_liqFor(_price(key), 1 ether)));
        vm.prank(victim, victim);
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, VolatilityGuardHookV9.PriceOffOracle.selector));
        lp.modifyLiquidity{value: 10 ether}(key, IPoolManager.ModifyLiquidityParams(LO, HI, liq, 0), "");
        console.log("5. dust liquidity + price moved to 2x: victim deposit REVERTED PriceOffOracle, nothing lost");
        _logUsd("   scammer spent moving the dust pool, USD", cost);
    }

    // ── 6. Sandwich a deposit inside the tolerance in a pool with real liquidity ──
    function test_attack6_sandwichDeposit() public {
        PoolKey memory key = _key(USDC, 60);
        vm.prank(honestLp, honestLp);
        PM.initialize(key, fair);
        int256 honest = int256(uint256(_liqFor(fair, 50 ether))); // ~$180k honest liquidity
        vm.prank(honestLp, honestLp);
        lp.modifyLiquidity{value: 200 ether}(key, IPoolManager.ModifyLiquidityParams(LO, HI, honest, 0), "");
        vm.warp(block.timestamp + 600);

        uint160 up = _scale(fair, 10140, 10000); // +2.8% in price, inside the tolerance
        int256 front = _swapTo(scammer, key, up);

        int256 liq = int256(uint256(_liqFor(up, 5 ether)));
        vm.prank(victim, victim);
        BalanceDelta dIn = lp.modifyLiquidity{value: 10 ether}(key, IPoolManager.ModifyLiquidityParams(LO, HI, liq, 0), "");

        int256 back = _swapTo(scammer, key, fair);
        vm.prank(victim, victim);
        BalanceDelta dOut = lp.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(LO, HI, -liq, 0), "");

        console.log("6. sandwich of a ~$18k deposit inside the 3% tolerance, $180k honest pool:");
        _logUsd("   scammer P&L (front + back), USD", front + back);
        _logUsd("   victim  P&L, USD", _value(dIn) + _value(dOut));
    }

    // ── 7. A token without an oracle (VJDX) ──
    function test_attack7_noOracleToken() public {
        PoolKey memory key = _key(VJDX, 60);
        vm.prank(scammer, scammer);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.UnauthorizedInitializer.selector));
        PM.initialize(key, fair);
        vm.prank(scammer, scammer);
        assertEq(IPoolInitializer(POSM).initializePool(key, fair), type(int24).max);
        assertEq(_price(key), 0);
        console.log("7. VJDX (no oracle) by a stranger: REVERTED UnauthorizedInitializer, directly and via the UI path");
    }

    // ── 8. Fake "USDC" token and an unusual tick spacing ──
    function test_attack8_fakeTokenAndOtherSpacing() public {
        MockERC20 fake = new MockERC20("USD Coin", "USDC", 6);
        PoolKey memory fakeKey = _key(address(fake), 60);
        vm.prank(scammer, scammer);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.UnauthorizedInitializer.selector));
        PM.initialize(fakeKey, fair);

        PoolKey memory odd = _key(USDC, 7); // real USDC, odd tick spacing: still checked by token
        vm.prank(scammer, scammer);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, VolatilityGuardHookV9.PriceOffOracle.selector));
        PM.initialize(odd, _scale(fair, 7071, 10000));
        console.log("8. fake 'USDC' token: REVERTED UnauthorizedInitializer; real USDC with tickSpacing 7 at -50%: REVERTED PriceOffOracle");
    }

    // Helpers

    function _key(address token, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), 0x800000, spacing, IHooks(address(hook)));
    }

    function _price(PoolKey memory key) internal view returns (uint160 p) {
        (p,,,) = PM.getSlot0(key.toId());
    }

    function _scale(uint160 sp, uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(uint256(sp) * num / den);
    }

    /// @dev Full-range liquidity for `ethAmount` of ETH at price `sp`
    function _liqFor(uint160 sp, uint256 ethAmount) internal pure returns (uint128) {
        uint256 hi = TickMath.getSqrtPriceAtTick(HI);
        // L = amount0 * sp * hi / (hi - sp) / 2^96
        return uint128(FullMath.mulDiv(FullMath.mulDiv(ethAmount, sp, 1 << 96), hi, hi - sp));
    }

    /// @dev Swap the pool to `target` with a large budget; returns the trader's P&L valued at Chainlink
    function _swapTo(address who, PoolKey memory key, uint160 target) internal returns (int256) {
        uint160 now_ = _price(key);
        if (now_ == target) return 0;
        bool zeroForOne = target < now_;
        vm.prank(who, who);
        BalanceDelta d = swapper.swap{value: zeroForOne ? 500 ether : 0}(
            key,
            IPoolManager.SwapParams(zeroForOne, zeroForOne ? -500 ether : -5_000_000e6, target),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        return _value(d);
    }

    /// @dev Value of a delta (positive = received) in USDC units at the Chainlink price
    function _value(BalanceDelta d) internal view returns (int256) {
        int256 eth = d.amount0();
        uint256 ethAbs = uint256(eth < 0 ? -eth : eth);
        int256 ethUsdc = int256(FullMath.mulDiv(ethAbs, uint256(fair) * uint256(fair), 1 << 192));
        return (eth < 0 ? -ethUsdc : ethUsdc) + int256(d.amount1());
    }

    function _logUsd(string memory label, int256 usdc6) internal pure {
        string memory sign = usdc6 < 0 ? "-" : "+";
        uint256 a = uint256(usdc6 < 0 ? -usdc6 : usdc6);
        console.log(string.concat(label, ": ", sign, vm.toString(a / 1e6), ".", _two(a % 1e6 / 1e4)));
    }

    function _two(uint256 x) internal pure returns (string memory) {
        return x < 10 ? string.concat("0", vm.toString(x)) : vm.toString(x);
    }

    function _wrapped(bytes4 callback, bytes4 err) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(err),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}

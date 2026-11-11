// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {VolatilityGuardHookV8, IPriceFeed} from "../src/dynamic-fee(slv-V8).sol";

contract RejectsETH {
    receive() external payable {
        revert("no ETH");
    }
}

contract MockFeed is IPriceFeed {
    int256 public answer;
    bool public broken;

    constructor(int256 _answer) {
        answer = _answer;
    }

    function set(int256 _answer) external {
        answer = _answer;
    }

    function setBroken(bool _broken) external {
        broken = _broken;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (0, answer, 0, block.timestamp, 0);
    }
}

contract VolatilityGuardHookV8Test is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    Currency constant ETH = CurrencyLibrary.ADDRESS_ZERO;
    address treasury = address(0xA3);

    MockFeed feed;
    VolatilityGuardHookV8 hook;
    PoolKey hookKey; // native ETH / token
    PoolKey refKey;  // same pair, no hook, zero fee: the same swap without any fee

    IPoolManager.ModifyLiquidityParams wide = IPoolManager.ModifyLiquidityParams(-60000, 60000, 1000e18, 0);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        feed = new MockFeed(3000e8);
        hook = _deployHook(address(uint160(0x4000 << 144) | FLAGS), treasury);

        (hookKey,) = initPool(ETH, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(hookKey, wide, ZERO_BYTES);

        (refKey,) = initPool(ETH, currency1, IHooks(address(0)), 0, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(refKey, wide, ZERO_BYTES);
    }

    function _deployHook(address at, address _treasury) internal returns (VolatilityGuardHookV8) {
        deployCodeTo("dynamic-fee(slv-V8).sol:VolatilityGuardHookV8", abi.encode(manager, _treasury, feed), at);
        return VolatilityGuardHookV8(at);
    }

    /// @dev zeroForOne pays native ETH; any spare ETH is refunded by the router
    function _swap(PoolKey memory key, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        if (zeroForOne) {
            uint256 value = amount < 0 ? uint256(-amount) : 10_000 ether;
            return swapNativeInput(key, true, amount, ZERO_BYTES, value);
        }
        return swap(key, false, amount, ZERO_BYTES);
    }

    function _accrued() internal view returns (uint256) {
        return hook.accruedTreasury();
    }

    // --- Fee curve ---

    function test_feeCurve_endpoints() public view {
        assertEq(hook.feeForDeviation(0), 100);
        assertEq(hook.feeForDeviation(20), 100);
        assertEq(hook.feeForDeviation(110), 10050);
        assertEq(hook.feeForDeviation(200), 20000);
        assertEq(hook.feeForDeviation(type(uint256).max), 20000);
    }

    function testFuzz_feeCurve_alwaysInRange(uint256 deviation) public view {
        uint24 fee = hook.feeForDeviation(deviation);
        assertGe(fee, 100);
        assertLe(fee, 20000);
    }

    // --- Which pools ---

    function test_onlyNativeEthDynamicPools() public {
        PoolKey memory noEth = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(noEth, SQRT_PRICE_1_1);

        PoolKey memory staticFee = PoolKey(ETH, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(staticFee, SQRT_PRICE_1_1);
    }

    function test_config() public view {
        assertEq(hook.LP_BPS(), 9_000);
        assertEq(hook.TREASURY_BPS(), 1_000);
        assertEq(hook.treasury(), treasury);
        assertEq(hook.payoutThreshold(), uint256(100e8) * 1e18 / 3000e8, "$100 at $3000/ETH");
    }

    // --- Treasury share is always taken in ETH ---

    function test_ethIn_exactIn_takesTreasuryFromInput() public {
        _swap(hookKey, true, -1e18);
        assertEq(_accrued(), (1e18 * 10) / 1e6, "10 pips of the ETH input");
    }

    function test_ethOut_exactIn_takesTreasuryFromOutput() public {
        BalanceDelta d = _swap(hookKey, false, -1e18);
        uint256 out = uint256(uint128(d.amount0()));
        assertApproxEqAbs(_accrued(), (out * 10) / (1e6 - 10), 1, "10 pips of the ETH output");
    }

    function test_ethOut_exactOut_swapperGetsExactAmount() public {
        BalanceDelta d = _swap(hookKey, false, 1e15);
        assertEq(uint256(uint128(d.amount0())), 1e15, "exact ETH out");
        assertEq(_accrued(), (1e15 * 10) / 1e6, "10 pips of the ETH output");
    }

    function test_ethIn_exactOut_takesTreasuryFromInput() public {
        BalanceDelta d = _swap(hookKey, true, 1e15);
        assertEq(uint256(uint128(d.amount1())), 1e15, "exact token out");
        uint256 paid = uint256(uint128(-d.amount0()));
        assertApproxEqAbs(_accrued(), (paid * 10) / (1e6 + 10), 1, "10 pips of the ETH input");
    }

    /// @dev ETH in, exact in: the big move's own top-up comes in the token and goes to the LPs in full
    function test_ethSpecified_bigMove_topUpGoesToLPs() public {
        _swap(hookKey, true, -50e18);
        assertEq(_accrued(), (50e18 * 10) / 1e6, "treasury share at the pre-swap fee only");
        (, uint256 growth1) = manager.getFeeGrowthGlobals(hookKey.toId());
        assertGt(growth1, 0, "top-up donated in the token");
    }

    function test_tokenSideNeverAccrues() public {
        _swap(hookKey, false, -1e18);
        _swap(hookKey, true, -1e18);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    // --- LPs ---

    function test_lpGets90Percent() public {
        uint256 amountIn = 1e18;
        _swap(hookKey, false, -int256(amountIn)); // LP fee is charged on the token input

        PoolId id = hookKey.toId();
        (uint128 liq,, uint256 last1) =
            manager.getPositionInfo(id, address(modifyLiquidityRouter), wide.tickLower, wide.tickUpper, wide.salt);
        (, uint256 inside1) = manager.getFeeGrowthInside(id, wide.tickLower, wide.tickUpper);
        assertApproxEqAbs(((inside1 - last1) * liq) >> 128, (amountIn * 90) / 1e6, 1, "90 pips of the input");
    }

    function test_topUp_reachesLPs() public {
        _swap(hookKey, true, -50e18);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(hookKey.toId());
        assertGt(growth0, 0, "LP fee on the input");
        assertGt(growth1, 0, "donated top-up on the output");
    }

    // --- Payout ---

    function test_noPayout_belowThreshold() public {
        for (uint256 i; i < 5; i++) _swap(hookKey, true, -1e18);
        assertEq(treasury.balance, 0);
        assertGt(_accrued(), 0);
        assertLe(_accrued(), hook.payoutThreshold());
    }

    function test_payout_onceAbove100Usd_andThresholdRefreshes() public {
        feed.set(6000e8);
        _swap(hookKey, false, -50e18); // ~2% fee on an ETH output: ~0.1 ETH treasury share
        assertGt(treasury.balance, uint256(100e8) * 1e18 / 3000e8, "paid above the $100 threshold");
        assertEq(_accrued(), 1, "1 wei kept to keep the slot warm");
        assertEq(hook.payoutThreshold(), uint256(100e8) * 1e18 / 6000e8, "refreshed from the feed");
    }

    function test_feedDown_payoutStillHappens_thresholdKept() public {
        feed.setBroken(true);
        uint256 before = hook.payoutThreshold();
        _swap(hookKey, false, -50e18);
        assertGt(treasury.balance, 0);
        assertEq(hook.payoutThreshold(), before);
    }

    function test_treasuryRejectingETH_doesNotBlockSwaps() public {
        VolatilityGuardHookV8 h2 = _deployHook(address(uint160(0x5000 << 144) | FLAGS), address(new RejectsETH()));
        (PoolKey memory k,) = initPool(ETH, currency1, IHooks(address(h2)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 2000 ether}(k, wide, ZERO_BYTES);

        _swap(k, true, -50e18);
        _swap(k, false, -50e18);
        assertGt(h2.accruedTreasury(), h2.payoutThreshold(), "kept in the hook");
    }

    // --- What a swap pays ---

    function test_bigSwap_paysMaxFee_itself() public {
        uint256 snap = vm.snapshotState();
        BalanceDelta free = _swap(refKey, true, -50e18);
        vm.revertToState(snap);

        BalanceDelta paid = _swap(hookKey, true, -50e18);
        (, int24 tick,,) = manager.getSlot0(hookKey.toId());
        assertLt(tick, -200, "moved past fullTicks");

        uint256 effective = 1e6 - (uint256(uint128(paid.amount1())) * 1e6) / uint256(uint128(free.amount1()));
        console.log("effective fee of a big first swap, pips:", effective);
        assertGt(effective, 19000);
        assertLe(effective, 20000);
    }

    function testFuzz_traderNeverPaysMoreThan2Percent_exactIn(uint96 rawAmount, bool zeroForOne) public {
        int256 amount = int256(bound(uint256(rawAmount), 1e12, 400e18));
        uint256 snap = vm.snapshotState();
        BalanceDelta free = _swap(refKey, zeroForOne, -amount);
        vm.revertToState(snap);
        BalanceDelta paid = _swap(hookKey, zeroForOne, -amount);

        uint256 outFree = uint256(uint128(zeroForOne ? free.amount1() : free.amount0()));
        uint256 outPaid = uint256(uint128(zeroForOne ? paid.amount1() : paid.amount0()));
        assertGe(outPaid * 1e6, outFree * (1e6 - 20000), "paid more than 2%");
    }

    function testFuzz_traderNeverPaysMoreThan2Percent_exactOut(uint96 rawAmount, bool zeroForOne) public {
        int256 amount = int256(bound(uint256(rawAmount), 1e12, 300e18));
        uint256 snap = vm.snapshotState();
        BalanceDelta free = _swap(refKey, zeroForOne, amount);
        vm.revertToState(snap);
        BalanceDelta paid = _swap(hookKey, zeroForOne, amount);

        uint256 inFree = uint256(uint128(-(zeroForOne ? free.amount0() : free.amount1())));
        uint256 inPaid = uint256(uint128(-(zeroForOne ? paid.amount0() : paid.amount1())));
        assertGe(inFree * 1e6, inPaid * (1e6 - 20000), "paid more than 2%");
    }

    // --- Anchor behaviour ---

    function _fee() internal view returns (uint24) {
        return hook.currentFee(hookKey.toId());
    }

    function test_splittingInOneBlock_doesNotAvoidFee() public {
        for (uint256 i; i < 200; i++) _swap(hookKey, true, -0.2e18);
        assertEq(_fee(), 20000);
    }

    function test_dustSwaps_cannotHoldFeeUp() public {
        _swap(hookKey, true, -50e18);
        uint256 t = block.timestamp;
        // Without rounding protection a dust swap every 2s would freeze the anchor forever
        for (uint256 i; i < 400; i++) {
            t += 2;
            vm.warp(t);
            _swap(hookKey, true, -1000);
        }
        vm.warp(t + 300);
        _swap(hookKey, true, -1000);
        assertEq(_fee(), 100, "fee back to min");
    }

    function test_idleTime_doesNotForgetTheMove() public {
        vm.warp(block.timestamp + 10 days);
        _swap(hookKey, true, -50e18); // first swap after a long idle period
        vm.warp(block.timestamp + 12);
        _swap(hookKey, true, -1000);
        assertGt(_fee(), 15000, "next block still pays a high fee");
    }

    function test_feeDecays_afterMove() public {
        _swap(hookKey, true, -50e18);
        uint24 prev = 20001;
        uint256 t = block.timestamp;
        for (uint256 i; i < 15; i++) {
            t += 100;
            vm.warp(t);
            _swap(hookKey, true, -1000);
            uint24 fee = _fee();
            assertLe(fee, prev);
            prev = fee;
        }
        assertEq(prev, 100);
    }

    // --- Access ---

    function test_hookEntryPoints_onlyPoolManager() public {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams(true, -1, 0);
        vm.expectRevert(VolatilityGuardHookV8.NotPoolManager.selector);
        hook.beforeSwap(address(this), hookKey, p, "");
    }

    function test_noAdmin() public {
        (bool ok,) = address(hook).call(abi.encodeWithSignature("setTreasury(address)", address(1)));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
    }

    // --- Gas ---

    function test_gas_comparison() public {
        vm.warp(block.timestamp + 12);
        _swap(hookKey, true, -1e15); // warm pool state on both sides
        _swap(refKey, true, -1e15);
        _swap(hookKey, false, -1e15);
        _swap(refKey, false, -1e15);
        vm.warp(block.timestamp + 12);

        uint256 g = gasleft();
        _swap(refKey, true, -1e15);
        uint256 refIn = g - gasleft();
        g = gasleft();
        _swap(hookKey, true, -1e15);
        uint256 hookIn = g - gasleft();

        g = gasleft();
        _swap(refKey, false, -1e15);
        uint256 refOut = g - gasleft();
        g = gasleft();
        _swap(hookKey, false, -1e15);
        uint256 hookOut = g - gasleft();

        console.log("ETH -> token, extra gas:", hookIn - refIn);
        console.log("token -> ETH, extra gas:", hookOut - refOut);
    }
}

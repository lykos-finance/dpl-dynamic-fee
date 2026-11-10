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
import {VolatilityGuardHookV8} from "../src/dynamic-fee(slv-V8).sol";

contract RejectsETH {
    receive() external payable {
        revert("no ETH");
    }
}

contract VolatilityGuardHookV8Test is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address swapper = address(0x5A11); // tx.origin of the test swaps

    VolatilityGuardHookV8 hook;
    PoolKey hookKey;
    PoolKey refKey; // no hook, zero fee: the same swap without any fee

    IPoolManager.ModifyLiquidityParams wide = IPoolManager.ModifyLiquidityParams(-60000, 60000, 1000e18, 0);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(uint160(0x4000 << 144) | FLAGS);
        deployCodeTo("dynamic-fee(slv-V8).sol:VolatilityGuardHookV8", abi.encode(manager), hookAddr);
        hook = VolatilityGuardHookV8(hookAddr);

        (hookKey,) = initPool(currency0, currency1, IHooks(hookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(hookKey, wide, ZERO_BYTES);

        (refKey,) = initPool(currency0, currency1, IHooks(address(0)), 0, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(refKey, wide, ZERO_BYTES);

        // msg.sender stays this contract, only tx.origin changes: the rebate goes to `swapper`
        vm.startPrank(address(this), swapper);
    }

    function _removeAll(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory p) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(p.tickLower, p.tickUpper, -p.liquidityDelta, p.salt), ZERO_BYTES
        );
    }

    function _hookBalance(Currency c) internal view returns (uint256) {
        return c.balanceOf(address(hook)) + manager.balanceOf(address(hook), c.toId());
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

    // --- Split ---

    function test_split_isLP90_rebate10() public view {
        assertEq(hook.LP_BPS(), 9_000);
        assertEq(hook.SWAPPER_REBATE_BPS(), 1_000);
    }

    function test_noAdmin() public {
        (bool ok,) = address(hook).call(abi.encodeWithSignature("treasury()"));
        assertFalse(ok, "no treasury");
        (ok,) = address(hook).call(abi.encodeWithSignature("signerA()"));
        assertFalse(ok, "no signers");
        (ok,) = address(hook).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "no pause");
    }

    function test_calmSwap_chargesMinFee_andSplits() public {
        BalanceDelta d = swap(hookKey, true, -1e15, ZERO_BYTES);
        uint256 out = uint256(uint128(d.amount1()));
        // fee 100 pips: LP 90 pips on the input, rebate 10 pips of the output
        uint256 gross = (out * 1e6) / (1e6 - 10);
        assertApproxEqAbs(currency1.balanceOf(swapper), (gross * 10) / 1e6, 1, "rebate to tx.origin");
        assertEq(_hookBalance(currency0) + _hookBalance(currency1), 0, "hook keeps nothing");
    }

    function test_rebate_goesToTxOrigin_notToRouter() public {
        swap(hookKey, true, -1e18, ZERO_BYTES);
        assertGt(currency1.balanceOf(swapper), 0);
        assertEq(currency1.balanceOf(address(swapRouter)), 0);
    }

    function test_rebate_isTenPercentOfFee() public {
        swap(hookKey, true, -50e18, ZERO_BYTES);
        // Rebate of a max-fee swap is 2000 pips of the output
        assertApproxEqRel(currency1.balanceOf(swapper), (49e18 * 2000) / 1e6, 0.1e18);
    }

    function test_rebateFailure_doesNotBlockSwap_andIsNotCharged() public {
        (PoolKey memory ethKey,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            ethKey, IPoolManager.ModifyLiquidityParams(-600, 600, 1000e18, 0), ZERO_BYTES
        );
        address rejecting = address(new RejectsETH());

        // One-for-zero exact input: the rebate is paid in ETH, which this tx.origin rejects
        uint256 snap = vm.snapshotState();
        BalanceDelta normal = swap(ethKey, false, -1e18, ZERO_BYTES);
        vm.revertToState(snap);

        vm.stopPrank();
        vm.startPrank(address(this), rejecting);
        BalanceDelta kept = swap(ethKey, false, -1e18, ZERO_BYTES);
        assertEq(rejecting.balance, 0);
        assertGt(kept.amount0(), normal.amount0(), "swapper keeps the rebate in the output");
    }

    // --- What a swap pays ---

    function test_bigSwap_paysMaxFee_itself() public {
        uint256 snap = vm.snapshotState();
        BalanceDelta free = swap(refKey, true, -50e18, ZERO_BYTES);
        vm.revertToState(snap);

        BalanceDelta paid = swap(hookKey, true, -50e18, ZERO_BYTES);
        (, int24 tick,,) = manager.getSlot0(hookKey.toId());
        assertLt(tick, -200, "moved past fullTicks");

        uint256 effective = 1e6 - (uint256(uint128(paid.amount1())) * 1e6) / uint256(uint128(free.amount1()));
        console.log("effective fee of a big first swap, pips:", effective);
        assertGt(effective, 19000);
        assertLe(effective, 20000);
        uint256 net = 1e6 - ((uint256(uint128(paid.amount1())) + currency1.balanceOf(swapper)) * 1e6)
            / uint256(uint128(free.amount1()));
        console.log("after the rebate, pips:", net);
        assertGt(net, 17000);
        assertLe(net, 18000);
    }

    function testFuzz_traderNetFeeAtMost1_8Percent_exactIn(uint96 rawAmount, bool zeroForOne) public {
        int256 amount = int256(bound(uint256(rawAmount), 1e12, 400e18));
        uint256 snap = vm.snapshotState();
        BalanceDelta free = swap(refKey, zeroForOne, -amount, ZERO_BYTES);
        vm.revertToState(snap);
        BalanceDelta paid = swap(hookKey, zeroForOne, -amount, ZERO_BYTES);

        Currency outC = zeroForOne ? currency1 : currency0;
        uint256 outFree = uint256(uint128(zeroForOne ? free.amount1() : free.amount0()));
        uint256 outPaid = uint256(uint128(zeroForOne ? paid.amount1() : paid.amount0()));
        assertGe(outPaid * 1e6, outFree * (1e6 - 20000), "router side paid more than 2%");
        assertGe((outPaid + outC.balanceOf(swapper)) * 1e6, outFree * (1e6 - 18000), "net of rebate more than 1.8%");
    }

    function testFuzz_traderNetFeeAtMost1_8Percent_exactOut(uint96 rawAmount, bool zeroForOne) public {
        int256 amount = int256(bound(uint256(rawAmount), 1e12, 300e18));
        uint256 snap = vm.snapshotState();
        BalanceDelta free = swap(refKey, zeroForOne, amount, ZERO_BYTES);
        vm.revertToState(snap);
        BalanceDelta paid = swap(hookKey, zeroForOne, amount, ZERO_BYTES);

        Currency inC = zeroForOne ? currency0 : currency1;
        uint256 inFree = uint256(uint128(-(zeroForOne ? free.amount0() : free.amount1())));
        uint256 inPaid = uint256(uint128(-(zeroForOne ? paid.amount0() : paid.amount1())));
        assertGe(inFree * 1e6, inPaid * (1e6 - 20000), "router side paid more than 2%");
        assertGe(inFree * 1e6, (inPaid - inC.balanceOf(swapper)) * (1e6 - 18000), "net of rebate more than 1.8%");
    }

    // --- LPs ---

    function test_topUp_reachesLPs() public {
        swap(hookKey, true, -50e18, ZERO_BYTES);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(hookKey.toId());
        assertGt(growth0, 0, "LP fee on the input token");
        assertGt(growth1, 0, "donated top-up on the output token");
        assertEq(_hookBalance(currency0) + _hookBalance(currency1), 0, "hook keeps nothing");
    }

    /// @dev LP fees accrue in the position itself and are paid out by any decrease of it
    function test_lpShare_accruesInPosition_andIsPaidOnRemoval() public {
        uint256 amountIn = 1e18;
        swap(hookKey, true, -int256(amountIn), ZERO_BYTES);

        PoolId id = hookKey.toId();
        (uint128 liq, uint256 last0,) =
            manager.getPositionInfo(id, address(modifyLiquidityRouter), wide.tickLower, wide.tickUpper, wide.salt);
        (uint256 inside0,) = manager.getFeeGrowthInside(id, wide.tickLower, wide.tickUpper);
        uint256 owed0 = ((inside0 - last0) * liq) >> 128;
        assertApproxEqAbs(owed0, (amountIn * 90) / 1e6, 1, "LP owed 90% of the 100 pip fee");

        // Closing the position pays principal and accrued fees in one call, nothing is left behind
        uint256 bal0 = currency0.balanceOfSelf();
        _removeAll(hookKey, wide);
        assertGt(currency0.balanceOfSelf() - bal0, owed0, "fees paid with the liquidity");
        (, uint256 lastAfter,) =
            manager.getPositionInfo(id, address(modifyLiquidityRouter), wide.tickLower, wide.tickUpper, wide.salt);
        assertEq(lastAfter, inside0, "no fees left in the position");
    }

    function test_twoLPs_shareProRata() public {
        // A second LP with three times the liquidity in the same range
        IPoolManager.ModifyLiquidityParams memory big =
            IPoolManager.ModifyLiquidityParams(wide.tickLower, wide.tickUpper, 3000e18, bytes32(uint256(1)));
        modifyLiquidityRouter.modifyLiquidity(hookKey, big, ZERO_BYTES);
        swap(hookKey, true, -1e18, ZERO_BYTES);

        PoolId id = hookKey.toId();
        (uint256 inside0,) = manager.getFeeGrowthInside(id, wide.tickLower, wide.tickUpper);
        (uint128 l1, uint256 a,) =
            manager.getPositionInfo(id, address(modifyLiquidityRouter), wide.tickLower, wide.tickUpper, wide.salt);
        (uint128 l2, uint256 b,) =
            manager.getPositionInfo(id, address(modifyLiquidityRouter), wide.tickLower, wide.tickUpper, big.salt);
        uint256 owedSmall = ((inside0 - a) * l1) >> 128;
        uint256 owedBig = ((inside0 - b) * l2) >> 128;
        assertApproxEqAbs(owedBig, owedSmall * 3, 3, "same rules for every LP");
    }

    // --- Anchor behaviour ---

    function test_splittingInOneBlock_doesNotAvoidFee() public {
        uint24 last;
        for (uint256 i; i < 200; i++) {
            vm.recordLogs();
            swap(hookKey, true, -0.2e18, ZERO_BYTES);
            last = _lastTotalFee();
        }
        assertEq(last, 20000);
    }

    function test_dustSwaps_cannotHoldFeeUp() public {
        swap(hookKey, true, -50e18, ZERO_BYTES);
        uint256 t = block.timestamp;
        // Without rounding protection a dust swap every 2s would freeze the anchor forever
        for (uint256 i; i < 400; i++) {
            t += 2;
            vm.warp(t);
            swap(hookKey, true, -1000, ZERO_BYTES);
        }
        vm.warp(t + 300);
        vm.recordLogs();
        swap(hookKey, true, -1000, ZERO_BYTES);
        assertEq(_lastTotalFee(), 100, "fee back to min");
    }

    function test_idleTime_doesNotForgetTheMove() public {
        vm.warp(block.timestamp + 10 days);
        swap(hookKey, true, -50e18, ZERO_BYTES); // first swap after a long idle period
        vm.warp(block.timestamp + 12);
        vm.recordLogs();
        swap(hookKey, true, -1000, ZERO_BYTES);
        assertGt(_lastTotalFee(), 15000, "next block still pays a high fee");
    }

    function test_feeDecays_afterMove() public {
        swap(hookKey, true, -50e18, ZERO_BYTES);
        uint24 prev = 20001;
        uint256 t = block.timestamp;
        // Frequent swaps make the decay exponential with ANCHOR_PERIOD as its time constant
        for (uint256 i; i < 15; i++) {
            t += 100;
            vm.warp(t);
            vm.recordLogs();
            swap(hookKey, true, -1000, ZERO_BYTES);
            uint24 fee = _lastTotalFee();
            console.log((i + 1) * 100, fee);
            assertLe(fee, prev);
            prev = fee;
        }
        assertEq(prev, 100);
    }

    function _lastTotalFee() internal returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeeCharged(bytes32,uint24,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) (fee,,) = abi.decode(logs[i].data, (uint24, uint256, uint256));
        }
    }

    // --- Cap bypasses closed ---

    function test_staticPool_rejected() public {
        PoolKey memory k = PoolKey(currency0, currency1, 100_000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_hookEntryPoints_onlyPoolManager() public {
        vm.stopPrank();
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams(true, -1, 0);
        vm.expectRevert("not PoolManager");
        hook.beforeSwap(address(this), hookKey, p, "");
    }

    // --- Gas ---

    function test_gas_comparison() public {
        vm.warp(block.timestamp + 12);
        swap(hookKey, true, -1e15, ZERO_BYTES); // warm pool state on both sides
        swap(refKey, true, -1e15, ZERO_BYTES);
        vm.warp(block.timestamp + 12);

        uint256 g = gasleft();
        swap(refKey, true, -1e15, ZERO_BYTES);
        uint256 refGas = g - gasleft();

        g = gasleft();
        swap(hookKey, true, -1e15, ZERO_BYTES);
        uint256 hookGas = g - gasleft();

        console.log("swap without hook, gas:", refGas);
        console.log("swap with V8, 90/10 split + rebate, gas:", hookGas);
        console.log("difference, gas:", hookGas - refGas);
    }
}

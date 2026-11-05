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

    address signerA  = address(0xA1);
    address signerB  = address(0xA2);
    address treasury = address(0xA3);

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    VolatilityGuardHookV8 hook;
    PoolKey hookKey;
    PoolKey refKey; // no hook, zero fee: the same swap without any fee

    IPoolManager.ModifyLiquidityParams wide = IPoolManager.ModifyLiquidityParams(-60000, 60000, 1000e18, 0);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address payable hookAddr = payable(address(uint160(0x4000 << 144) | FLAGS));
        deployCodeTo(
            "dynamic-fee(slv-V8).sol:VolatilityGuardHookV8", abi.encode(manager, signerA, signerB, treasury), hookAddr
        );
        hook = VolatilityGuardHookV8(hookAddr);

        (hookKey,) = initPool(currency0, currency1, IHooks(hookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(hookKey, wide, ZERO_BYTES);

        (refKey,) = initPool(currency0, currency1, IHooks(address(0)), 0, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(refKey, wide, ZERO_BYTES);
    }

    function _claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
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

    // --- What a swap pays ---

    function test_calmSwap_chargesMinFee_andSplits90_10() public {
        BalanceDelta d = swap(hookKey, true, -1e15, ZERO_BYTES);
        uint256 out = uint256(uint128(d.amount1()));
        // totalFee 100 pips: treasury 10 pips, LP 90 pips
        assertEq(currency1.balanceOf(treasury), ((out * 1e6 / (1e6 - 10)) * 10) / 1e6, "treasury share");
        assertEq(_claims(currency1), 0, "nothing left in the hook");
    }

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
    }

    function testFuzz_traderNeverPaysMoreThan2Percent_exactIn(uint96 rawAmount, bool zeroForOne) public {
        int256 amount = int256(bound(uint256(rawAmount), 1e12, 400e18));
        uint256 snap = vm.snapshotState();
        BalanceDelta free = swap(refKey, zeroForOne, -amount, ZERO_BYTES);
        vm.revertToState(snap);
        BalanceDelta paid = swap(hookKey, zeroForOne, -amount, ZERO_BYTES);

        uint256 outFree = uint256(uint128(zeroForOne ? free.amount1() : free.amount0()));
        uint256 outPaid = uint256(uint128(zeroForOne ? paid.amount1() : paid.amount0()));
        assertGe(outPaid * 1e6, outFree * (1e6 - 20000), "paid more than 2%");
    }

    function testFuzz_traderNeverPaysMoreThan2Percent_exactOut(uint96 rawAmount, bool zeroForOne) public {
        int256 amount = int256(bound(uint256(rawAmount), 1e12, 300e18));
        uint256 snap = vm.snapshotState();
        BalanceDelta free = swap(refKey, zeroForOne, amount, ZERO_BYTES);
        vm.revertToState(snap);
        BalanceDelta paid = swap(hookKey, zeroForOne, amount, ZERO_BYTES);

        uint256 inFree = uint256(uint128(-(zeroForOne ? free.amount0() : free.amount1())));
        uint256 inPaid = uint256(uint128(-(zeroForOne ? paid.amount0() : paid.amount1())));
        assertGe(inFree * 1e6, inPaid * (1e6 - 20000), "paid more than 2%");
    }

    function test_topUp_reachesLPs() public {
        swap(hookKey, true, -50e18, ZERO_BYTES);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(hookKey.toId());
        assertGt(growth0, 0, "LP fee on the input token");
        assertGt(growth1, 0, "donated top-up on the output token");
    }

    function test_treasuryShareIsTenPercentOfTotalFee() public {
        swap(hookKey, true, -50e18, ZERO_BYTES);
        // Treasury share of a max-fee swap is 2000 pips of the output
        assertApproxEqRel(currency1.balanceOf(treasury), (49e18 * 2000) / 1e6, 0.1e18);
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

    // --- Treasury ---

    function test_exactOut_paysTreasuryImmediately() public {
        swap(hookKey, true, 1e15, ZERO_BYTES);
        assertGt(currency0.balanceOf(treasury), 0);
        assertEq(_claims(currency0), 0);
    }

    function _setTreasury(address newTreasury) internal {
        vm.prank(signerA);
        hook.proposeSetTreasury(newTreasury);
        vm.prank(signerB);
        hook.confirmAndExecuteSetTreasury(newTreasury);
        vm.warp(block.timestamp + 15 minutes);
        vm.prank(signerB);
        hook.confirmAndExecuteSetTreasury(newTreasury);
    }

    function _ethPoolWithStuckClaims() internal returns (uint256 claims) {
        _setTreasury(address(new RejectsETH()));
        (PoolKey memory ethKey,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            ethKey, IPoolManager.ModifyLiquidityParams(-600, 600, 1000e18, 0), ZERO_BYTES
        );
        // One-for-zero exact input: the treasury share is taken in ETH
        swap(ethKey, false, -1e18, ZERO_BYTES);
        claims = _claims(CurrencyLibrary.ADDRESS_ZERO);
    }

    function test_treasuryRejectingETH_doesNotBlockSwaps() public {
        assertGt(_ethPoolWithStuckClaims(), 0, "share kept in the hook");
    }

    function test_sweep_paysOnlyTreasury() public {
        uint256 claims = _ethPoolWithStuckClaims();
        vm.expectRevert();
        hook.sweepToTreasury(CurrencyLibrary.ADDRESS_ZERO); // this treasury rejects ETH

        _setTreasury(treasury);
        vm.prank(address(0xBAD));
        hook.sweepToTreasury(CurrencyLibrary.ADDRESS_ZERO);
        assertEq(treasury.balance, claims);
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO), 0);
    }

    // --- Access control ---

    function test_setTreasury_needsBothSignersAndTimelock() public {
        address newTreasury = address(0xB0B);

        vm.expectRevert("not a signer");
        hook.proposeSetTreasury(newTreasury);

        vm.prank(signerB);
        vm.expectRevert(VolatilityGuardHookV8.NotProposedYet.selector);
        hook.confirmAndExecuteSetTreasury(newTreasury);

        vm.prank(signerA);
        hook.proposeSetTreasury(newTreasury);

        vm.prank(signerA);
        vm.expectRevert(VolatilityGuardHookV8.AlreadyConfirmed.selector);
        hook.confirmAndExecuteSetTreasury(newTreasury);

        vm.prank(signerB);
        hook.confirmAndExecuteSetTreasury(newTreasury);
        assertEq(hook.treasury(), treasury, "first confirm only starts the timelock");

        vm.warp(block.timestamp + 15 minutes - 1);
        vm.prank(signerB);
        vm.expectRevert(VolatilityGuardHookV8.TimelockNotElapsed.selector);
        hook.confirmAndExecuteSetTreasury(newTreasury);

        vm.warp(block.timestamp + 1);
        vm.prank(signerB);
        hook.confirmAndExecuteSetTreasury(newTreasury);
        assertEq(hook.treasury(), newTreasury);

        swap(hookKey, true, -1e15, ZERO_BYTES);
        assertGt(currency1.balanceOf(newTreasury), 0);

        vm.prank(signerB);
        vm.expectRevert(VolatilityGuardHookV8.NotProposedYet.selector);
        hook.confirmAndExecuteSetTreasury(newTreasury);
    }

    function test_confirm_atDeadlineWorks_afterItExpires() public {
        address newTreasury = address(0xB0B);
        vm.prank(signerA);
        hook.proposeSetTreasury(newTreasury);
        uint256 proposedAt = block.timestamp;

        vm.warp(proposedAt + 30 minutes + 1);
        vm.prank(signerB);
        vm.expectRevert(VolatilityGuardHookV8.ProposalExpired.selector);
        hook.confirmAndExecuteSetTreasury(newTreasury);

        vm.prank(signerA);
        hook.proposeSetTreasury(newTreasury); // a new proposal restarts the window
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(signerB);
        hook.confirmAndExecuteSetTreasury(newTreasury);
        (,, uint256 confirmedAt) = hook.pendingActions(keccak256(abi.encode("setTreasury", newTreasury)));
        assertEq(confirmedAt, block.timestamp);
    }

    function test_execute_atDeadlineWorks() public {
        address newTreasury = address(0xB0B);
        vm.prank(signerA);
        hook.proposeSetTreasury(newTreasury);
        vm.prank(signerB);
        hook.confirmAndExecuteSetTreasury(newTreasury);

        vm.warp(block.timestamp + 15 minutes + 30 minutes);
        vm.prank(signerB);
        hook.confirmAndExecuteSetTreasury(newTreasury);
        assertEq(hook.treasury(), newTreasury);
    }

    function test_execute_afterDeadline_expires_andNeedsNewProposal() public {
        address newTreasury = address(0xB0B);
        vm.prank(signerA);
        hook.proposeSetTreasury(newTreasury);
        vm.prank(signerB);
        hook.confirmAndExecuteSetTreasury(newTreasury);

        uint256 t = block.timestamp + 15 minutes + 30 minutes + 1;
        vm.warp(t);
        vm.prank(signerB);
        vm.expectRevert(VolatilityGuardHookV8.ProposalExpired.selector);
        hook.confirmAndExecuteSetTreasury(newTreasury);
        assertEq(hook.treasury(), treasury);

        // The full flow works again from a new proposal
        vm.prank(signerB);
        hook.proposeSetTreasury(newTreasury);
        vm.prank(signerA);
        hook.confirmAndExecuteSetTreasury(newTreasury);
        vm.warp(t + 15 minutes);
        vm.prank(signerA);
        hook.confirmAndExecuteSetTreasury(newTreasury);
        assertEq(hook.treasury(), newTreasury);
    }

    function test_noPause_noAdminCanStopSwaps() public {
        (bool ok,) = address(hook).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "no pause function");
        swap(hookKey, true, -1e15, ZERO_BYTES);
    }

    function test_hookEntryPoints_onlyPoolManager() public {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams(true, -1, 0);
        vm.expectRevert("not PoolManager");
        hook.beforeSwap(address(this), hookKey, p, "");
        vm.expectRevert("not PoolManager");
        hook.unlockCallback(abi.encode(currency1, 1));
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
        console.log("swap with V8, 10% treasury, gas:", hookGas);
        console.log("difference, gas:", hookGas - refGas);
    }
}

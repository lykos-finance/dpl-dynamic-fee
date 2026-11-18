// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolPriceAligner} from "../src/PoolPriceAligner.sol";
import {AlignPriceV8} from "../script/AlignPriceV8(slv).s.sol";
import {InitPoolV8} from "../script/InitPoolV8(slv).s.sol";
import {DeployV8, HookFactoryV8} from "../script/DeployV8(slv).s.sol";
import {VolatilityGuardHookV8} from "../src/dynamic-fee(slv-V8).sol";

interface IERC20A { function approve(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IFeedT { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }

/// @notice PoolPriceAligner against the live empty ETH/USDC pool of hook 0xC971...70Cc on a mainnet fork
contract PoolPriceAlignerForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant HOOK = 0xC971D348357BDD36FC444045bA96e9494A3970Cc;

    function _key(address hook) internal pure returns (PoolKey memory) {
        return PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), 0x800000, 60, IHooks(hook));
    }

    /// @dev One test: the scripts read env vars set with vm.setEnv, which parallel tests would race on
    function test_aligner() public {
        _alignLiveEmptyPoolToChainlink();
        _alignUpEmptyPoolNeedsNoToken();
        _alignUpAndRefuseWithLiquidity();
    }

    function _alignLiveEmptyPoolToChainlink() internal {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        PoolKey memory key = _key(HOOK);
        if (PM.getLiquidity(key.toId()) != 0) return; // the live pool got liquidity since: nothing to test

        uint256 pk = uint256(keccak256("aligner fork key"));
        address me = vm.addr(pk);
        vm.deal(me, 1 ether);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(pk)));
        vm.setEnv("HOOK_ADDRESS_V8", vm.toString(HOOK));

        uint256 accrued0 = VolatilityGuardHookV8(HOOK).accruedTreasury();
        new AlignPriceV8().run();

        (uint160 sp,,,) = PM.getSlot0(key.toId());
        (, int256 answer,,,) = IFeedT(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419).latestRoundData();
        uint256 poolUsd8 = (uint256(sp) * uint256(sp) * 1e20) >> 192;
        assertApproxEqRel(poolUsd8, uint256(answer), 1e12); // within 0.0001%
        uint256 spent = 1 ether - me.balance;
        assertLt(spent, 1e8, "aligning an empty pool must cost only dust");
        assertEq(VolatilityGuardHookV8(HOOK).accruedTreasury() - accrued0, spent);
        console.log("aligned to USD*1e8:", poolUsd8, "spent wei:", spent);
    }

    function _alignUpAndRefuseWithLiquidity() internal {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        // Fresh hook + pool with $20/side so the pool has liquidity
        address treasury = address(uint160(uint256(keccak256("aligner fork treasury"))));
        uint256 pk = uint256(keccak256("aligner fork key 2"));
        address me = vm.addr(pk);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(pk)));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.recordLogs();
        new DeployV8().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address hook;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == HookFactoryV8.HookDeployed.selector) hook = address(uint160(uint256(logs[i].topics[1])));
        }
        vm.setEnv("HOOK_ADDRESS_V8", vm.toString(hook));
        vm.setEnv("LP_USDC_PER_SIDE", "20000000");
        vm.setEnv("LP_RANGE_BELOW_PCT", "50");
        vm.setEnv("LP_RANGE_ABOVE_PCT", "100");
        vm.deal(me, 1 ether);
        deal(USDC, me, 100e6);
        new InitPoolV8().run();

        PoolKey memory key = _key(hook);
        PoolPriceAligner aligner = new PoolPriceAligner(PM);
        (uint160 sp,,,) = PM.getSlot0(key.toId());

        // With liquidity in the way and a dust budget the target is out of reach: revert, nothing changes
        // Moving the price up spends USDC: budget 1 USDC, far too little to lift a $40 pool by 44%
        uint160 up = uint160(uint256(sp) * 120 / 100);
        vm.startPrank(me);
        IERC20A(USDC).approve(address(aligner), type(uint256).max);
        uint256 usdc0 = IERC20A(USDC).balanceOf(me);
        vm.expectRevert(PoolPriceAligner.TargetNotReached.selector);
        aligner.align(key, up, 1e6);
        vm.stopPrank();
        assertEq(IERC20A(USDC).balanceOf(me), usdc0);
        (uint160 spAfter,,,) = PM.getSlot0(key.toId());
        assertEq(spAfter, sp);

        // The script refuses pools with liquidity outright. Create it first: expectRevert applies to the next call
        AlignPriceV8 script = new AlignPriceV8();
        vm.expectRevert("Pool has active liquidity - not an empty pool");
        script.run();
    }

    function _alignUpEmptyPoolNeedsNoToken() internal {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        PoolKey memory key = _key(HOOK);
        if (PM.getLiquidity(key.toId()) != 0) return;
        PoolPriceAligner aligner = new PoolPriceAligner(PM);
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        uint160 up = uint160(uint256(sp) * 110 / 100);
        address me = address(uint160(uint256(keccak256("aligner up"))));
        // USDC input, no approval and no balance: an empty pool must not need any token
        vm.prank(me);
        aligner.align(key, up, 1e6);
        (uint160 after_,,,) = PM.getSlot0(key.toId());
        assertEq(after_, up);
    }
}

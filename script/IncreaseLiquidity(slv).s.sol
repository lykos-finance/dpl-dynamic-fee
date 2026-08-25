// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
}

/// @notice Add more liquidity to an EXISTING position (NFT). Uses INCREASE_LIQUIDITY.
/// @dev ENV:
///   PRIVATE_KEY  — signer (must own TOKEN_ID)
///   HOOK_ADDRESS — hook of the pool
///   TOKEN_ID     — existing position NFT id (e.g. 206666)
contract IncreaseLiquidity is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER  = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2           = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH              = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT              = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() public {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address hookAddr = vm.envAddress("HOOK_ADDRESS_V3");
        uint256 tokenId  = vm.envUint("TOKEN_ID");
        address deployer = vm.addr(pk);

        // Amounts to add — overridable via ENV (defaults: $20 + $20)
        uint256 ADD_USDT = vm.envOr("ADD_USDT_UNITS", uint256(20_000_000));
        uint256 ADD_WETH = vm.envOr("ADD_WETH_WEI",   uint256(8_500_000_000_000_000));

        console.log("=== IncreaseLiquidity ===");
        console.log("Deployer:", deployer);
        console.log("TokenId: ", tokenId);

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        IPositionManager pm  = IPositionManager(POSITION_MANAGER);

        // ── 1. PoolKey (WETH=token0, USDT=token1) ──
        PoolKey memory key = PoolKey(
            Currency.wrap(WETH),
            Currency.wrap(USDT),
            0x800000,
            60,
            IHooks(hookAddr)
        );
        PoolId poolId = key.toId();
        (uint160 sqrtCurrent, int24 currentTick, , ) = manager.getSlot0(poolId);
        require(sqrtCurrent != 0, "Pool not initialized");
        console.log("Pool sqrtPriceX96:", uint256(sqrtCurrent));
        console.logInt(int256(currentTick));

        // ── 2. Compute liquidity from available amounts (use min as binding) ──
        // We want to add up to ADD_WETH + ADD_USDT. Since we don't know ticks here, we
        // just pass amounts as maxes and let INCREASE_LIQUIDITY figure out liquidity.
        // For INCREASE_LIQUIDITY we must specify exact `liquidity`. Easier: re-derive
        // liquidity approximately from USDT side using the position's ticks — but we
        // don't have them here without reading NFT. Workaround: pass a conservative
        // liquidity and cap with amount maxes.
        // Simpler alternative: use INCREASE_LIQUIDITY_FROM_DELTAS (but it's deprecated).
        // Cleanest: compute liquidity using StateLibrary + position's tick bounds.

        // Tick range — pass via env to match the actual position:
        //   V2 pool ($2000-$2420): TICK_LOWER=-200340 TICK_UPPER=-198360
        //   V3 pool ($2000-$2400): TICK_LOWER=-200340 TICK_UPPER=-198480 (default)
        int24 tickLower = int24(int256(vm.envOr("TICK_LOWER", int256(-200340))));
        int24 tickUpper = int24(int256(vm.envOr("TICK_UPPER", int256(-198480))));
        console.log("Using tickLower:"); console.logInt(int256(tickLower));
        console.log("Using tickUpper:"); console.logInt(int256(tickUpper));
        uint160 sqrtLower = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = _getSqrtRatioAtTick(tickUpper);
        uint256 Q96 = 2**96;

        // L from USDT: L = amount1 * Q96 / (sqrtCurrent - sqrtLower)
        uint128 L_usdt = uint128((ADD_USDT * Q96) / (uint256(sqrtCurrent) - uint256(sqrtLower)));
        // L from WETH: L = amount0 * sqrtCurrent * sqrtUpper / (Q96 * (sqrtUpper - sqrtCurrent))
        uint128 L_weth = uint128(
            (ADD_WETH * uint256(sqrtCurrent) * uint256(sqrtUpper)) /
            (Q96 * (uint256(sqrtUpper) - uint256(sqrtCurrent)))
        );
        uint128 liquidity = L_weth < L_usdt ? L_weth : L_usdt;
        console.log("L_weth:", L_weth);
        console.log("L_usdt:", L_usdt);
        console.log("Using L:", liquidity);

        // Compute actual amounts from chosen L, +5% buffer
        uint256 amount0Max = (uint256(liquidity) * Q96 *
            (uint256(sqrtUpper) - uint256(sqrtCurrent))) /
            (uint256(sqrtCurrent) * uint256(sqrtUpper));
        uint256 amount1Max = (uint256(liquidity) *
            (uint256(sqrtCurrent) - uint256(sqrtLower))) / Q96;
        amount0Max = amount0Max * 105 / 100;
        amount1Max = amount1Max * 105 / 100;
        console.log("amount0Max WETH:", amount0Max);
        console.log("amount1Max USDT:", amount1Max);

        require(IERC20Like(WETH).balanceOf(deployer) >= amount0Max, "Not enough WETH");
        require(IERC20Like(USDT).balanceOf(deployer) >= amount1Max, "Not enough USDT");

        // ════════════════════════════════════════════════════════════════════
        vm.startBroadcast(pk);

        // ── 3. Approvals (idempotent, skip if already set for this deployer) ──
        _ensureApprove(WETH, deployer, amount0Max);
        _ensureApprove(USDT, deployer, amount1Max);
        IAllowanceTransfer(PERMIT2).approve(WETH, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2).approve(USDT, POSITION_MANAGER, type(uint160).max, type(uint48).max);

        // ── 4. INCREASE_LIQUIDITY + CLOSE_CURRENCY x2 ──
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            tokenId,
            uint256(liquidity),
            uint128(amount0Max),
            uint128(amount1Max),
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);

        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);

        vm.stopBroadcast();
        // ════════════════════════════════════════════════════════════════════
        console.log("=== DONE - liquidity added to tokenId ===");
    }

    /// @dev Reads allowance for the actual `owner` (deployer), not msg.sender of the Script.
    function _ensureApprove(address token, address owner, uint256 needed) internal {
        (bool okA, bytes memory d) = token.staticcall(
            abi.encodeWithSignature("allowance(address,address)", owner, PERMIT2)
        );
        require(okA, "allowance read failed");
        uint256 current = abi.decode(d, (uint256));
        if (current >= needed) return; // already enough for this run
        if (current != 0) {
            (bool ok0, ) = token.call(abi.encodeWithSignature("approve(address,uint256)", PERMIT2, 0));
            require(ok0, "approve(0) failed");
        }
        (bool ok1, ) = token.call(abi.encodeWithSignature("approve(address,uint256)", PERMIT2, type(uint256).max));
        require(ok1, "approve(max) failed");
    }

    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= 887272, "T");
            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2     != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4     != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8     != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10    != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20    != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40    != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80    != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100   != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200   != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400   != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800   != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000  != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000  != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000  != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000  != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9)  >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604)   >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98)      >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2)           >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }
}

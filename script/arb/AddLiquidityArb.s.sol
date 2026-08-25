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

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
    function allowance(address, address) external view returns (uint256);
}

/// @notice Adds liquidity to an existing Uniswap v4 pool on Arbitrum (mints new LP NFT).
/// @dev ENV:
///   PRIVATE_KEY       — signer
///   HOOK_ADDRESS_ARB  — existing hook address
///   TARGET_USDT_USD   — (optional) USDT amount in whole dollars (default 5)
///   TARGET_WETH_USD   — (optional) WETH amount in USD (default 2)
contract AddLiquidityArb is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Arbitrum One addresses
    address constant POOL_MANAGER      = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant POSITION_MANAGER  = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address constant PERMIT2           = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH              = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDT              = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    function run() public {
        require(block.chainid == 42161, "Wrong chain - need Arbitrum");

        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address hookAddr = vm.envAddress("HOOK_ADDRESS_ARB");
        address deployer = vm.addr(pk);

        uint256 targetUsdUSDT = vm.envOr("TARGET_USDT_USD", uint256(5));
        uint256 targetUsdWETH = vm.envOr("TARGET_WETH_USD", uint256(2));

        console.log("=== AddLiquidityArb ===");
        console.log("Deployer:", deployer);
        console.log("Hook:    ", hookAddr);
        console.log("Target:  ", targetUsdUSDT, "USDT +", targetUsdWETH);

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        IPositionManager pm = IPositionManager(POSITION_MANAGER);

        // ── 1. Sort tokens ──
        IERC20Like tokenA = IERC20Like(WETH);
        IERC20Like tokenB = IERC20Like(USDT);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        console.log("[1] Token0:", tokenA.symbol());
        console.log("[1] Token1:", tokenB.symbol());

        // ── 2. PoolKey + read actual pool state ──
        PoolKey memory key = PoolKey(
            Currency.wrap(address(tokenA)),
            Currency.wrap(address(tokenB)),
            0x800000, 60, IHooks(hookAddr)
        );
        PoolId poolId = key.toId();

        (uint160 sqrtCurrent, int24 currentTick, , ) = manager.getSlot0(poolId);
        require(sqrtCurrent != 0, "Pool not initialized");
        console.log("[2] sqrtPrice:", uint256(sqrtCurrent));
        console.logInt(int256(currentTick));

        // ── 3. Chainlink price ──
        (, int256 ethAnswer, , uint256 updatedAt, ) =
            AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        require(ethAnswer > 0, "Chainlink: invalid price");
        require(block.timestamp - updatedAt < 7200, "Chainlink: stale price");
        uint256 ethPriceUSD8 = uint256(ethAnswer);
        console.log("[3] ETH/USD (x1e8):", ethPriceUSD8);

        // ── 4. Tick range: $2000 - $2420 ──
        uint160 sqrtAtPriceLower = uint160(sqrtU256(2000 * 1e8) * (1 << 96) / 1e10);
        uint160 sqrtAtPriceUpper = uint160(sqrtU256(2420 * 1e8) * (1 << 96) / 1e10);
        int24 rawLower = getTickFromSqrtPrice(sqrtAtPriceLower);
        int24 rawUpper = getTickFromSqrtPrice(sqrtAtPriceUpper);
        int24 tickLower = rawLower >= 0 ? (rawLower / 60) * 60 : ((rawLower - 59) / 60) * 60;
        int24 tickUpper = rawUpper >= 0 ? ((rawUpper + 59) / 60) * 60 : (rawUpper / 60) * 60;

        require(tickLower < currentTick && currentTick < tickUpper, "Current tick out of range");
        console.log("[4] tickLower:"); console.logInt(int256(tickLower));
        console.log("[4] tickUpper:"); console.logInt(int256(tickUpper));

        uint160 sqrtLower = getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = getSqrtRatioAtTick(tickUpper);

        // ── 5. Compute liquidity ──
        uint256 Q96 = 2**96;
        uint256 targetUSDT = targetUsdUSDT * 1_000_000;
        uint256 targetWETH = (targetUsdWETH * 1_000_000 * 1e20) / ethPriceUSD8;

        uint128 liquidityFromWETH = uint128(
            (targetWETH * uint256(sqrtCurrent) * uint256(sqrtUpper)) /
            (Q96 * (uint256(sqrtUpper) - uint256(sqrtCurrent)))
        );
        uint128 liquidityFromUSDT = uint128(
            (targetUSDT * Q96) / (uint256(sqrtCurrent) - uint256(sqrtLower))
        );
        uint128 liquidityAmount = liquidityFromWETH < liquidityFromUSDT
            ? liquidityFromWETH : liquidityFromUSDT;
        console.log("[5] Liquidity:", liquidityAmount);

        // ── 6. Compute max token amounts (+5% slippage buffer) ──
        uint256 amount0Max = (uint256(liquidityAmount) * Q96 *
            (uint256(sqrtUpper) - uint256(sqrtCurrent))) /
            (uint256(sqrtCurrent) * uint256(sqrtUpper));
        uint256 amount1Max = (uint256(liquidityAmount) *
            (uint256(sqrtCurrent) - uint256(sqrtLower))) / Q96;
        amount0Max = amount0Max * 105 / 100;
        amount1Max = amount1Max * 105 / 100;
        console.log("[6] amount0Max WETH:", amount0Max);
        console.log("[6] amount1Max USDT:", amount1Max);

        require(tokenA.balanceOf(deployer) >= amount0Max, "Not enough token0 (WETH)");
        require(tokenB.balanceOf(deployer) >= amount1Max, "Not enough token1 (USDT)");

        vm.startBroadcast(pk);

        // ── 7. Approvals (USDT-safe) ──
        _safeApproveUSDT(address(tokenA), PERMIT2, deployer);
        _safeApproveUSDT(address(tokenB), PERMIT2, deployer);

        IAllowanceTransfer(PERMIT2).approve(address(tokenA), POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2).approve(address(tokenB), POSITION_MANAGER, type(uint160).max, type(uint48).max);

        // ── 8. Mint new LP position ──
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidityAmount),
            uint128(amount0Max), uint128(amount1Max), deployer, bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);

        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);

        console.log("[8] LP minted. Next tokenId:", pm.nextTokenId());

        vm.stopBroadcast();
        console.log("=== DONE ===");
    }

    // ── Helpers ──

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "approve failed");
    }

    function _safeApproveUSDT(address token, address spender, address owner) internal {
        (bool okA, bytes memory d) = token.staticcall(
            abi.encodeWithSignature("allowance(address,address)", owner, spender)
        );
        uint256 current = okA && d.length >= 32 ? abi.decode(d, (uint256)) : 0;
        if (current >= type(uint128).max) return;
        if (current != 0) _safeApprove(token, spender, 0);
        _safeApprove(token, spender, type(uint256).max);
    }

    function getTickFromSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        int24 lo = -887220; int24 hi = 887220;
        while (lo < hi) {
            int24 mid = lo + (hi - lo + 1) / 2;
            if (getSqrtRatioAtTick(mid) <= sqrtPriceX96) lo = mid; else hi = mid - 1;
        }
        tick = lo;
    }

    function sqrtU256(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
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

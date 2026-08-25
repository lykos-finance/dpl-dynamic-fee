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
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
}

/// @notice Creates a standard WETH/USDT v4 pool with 0.30% fixed fee, no hook
///         Range: $2000 - $2500
contract InitPoolNoHook is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;    

    // ── Mainnet addresses ──
    address constant POOL_MANAGER      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER  = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2           = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH              = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT              = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    int24 constant TICK_SPACING = 59;

    function run() public {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== InitPoolNoHook (0.30% fixed fee, range $2000-$2500) ===");
        console.log("Deployer:", deployer);

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        IPositionManager pm  = IPositionManager(POSITION_MANAGER);

        // ── 1. Sort tokens ──
        IERC20Like tokenA = IERC20Like(WETH);
        IERC20Like tokenB = IERC20Like(USDT);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        console.log("[1] Token0:", tokenA.symbol(), address(tokenA));
        console.log("[1] Token1:", tokenB.symbol(), address(tokenB));

        // ── 2. Chainlink price ──
        (, int256 ethAnswer, , uint256 updatedAt, ) =
            AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        require(ethAnswer > 0, "Chainlink: invalid price");
        require(block.timestamp - updatedAt < 7200, "Chainlink: stale price");
        uint256 ethPriceUSD8 = uint256(ethAnswer);
        console.log("[2] ETH/USD (x1e8):", ethPriceUSD8);

        // ── 3. Compute sqrtPrice aligned to tickSpacing ──
        // FIX: use _floorTick() which correctly handles negative ticks.
        // Solidity truncates toward zero: -69423/58 = -1197 (not -1198),
        // so naive `tick/58*58` rounds UP for negatives - wrong direction.
        uint160 startSqrtPrice = uint160(sqrtU256(ethPriceUSD8) * (1 << 96) / 1e10);
        int24 currentTick = getTickFromSqrtPrice(startSqrtPrice);
        currentTick    = _floorTick(currentTick, TICK_SPACING);
        startSqrtPrice = getSqrtRatioAtTick(currentTick);
        console.log("[3] currentTick (aligned):"); console.logInt(int256(currentTick));

        // ── 4. PoolKey ──
        PoolKey memory key = PoolKey(
            Currency.wrap(address(tokenA)),
            Currency.wrap(address(tokenB)),
            3000,
            TICK_SPACING,
            IHooks(address(0))
        );
        PoolId poolId = key.toId();
        console.log("[4] PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));

        // ── Check if pool already initialized ──
        (uint160 existingSqrt, , , ) = manager.getSlot0(poolId);
        bool needsInit = (existingSqrt == 0);
        console.log("[4] Pool already initialized:", !needsInit);

        // ════════════════════════════════════════════════════════════════════
        // START BROADCAST
        // ════════════════════════════════════════════════════════════════════
        vm.startBroadcast(pk);

        // ── 5. Initialize pool (skip if already exists) ──
        if (needsInit) {
            console.log("[5] Initializing pool...");
            manager.initialize(key, startSqrtPrice);
            console.log("[5] Pool initialized OK");
        } else {
            console.log("[5] Pool already exists - skipping initialize");
        }

        // ── 6. Read actual pool state ──
        (uint160 actualSqrtPrice, int24 actualTick, , ) = manager.getSlot0(poolId);
        console.log("[6] Actual pool tick:"); console.logInt(int256(actualTick));

        // ── Tick range: $2000 - $2500 aligned to tickSpacing=59 ──
        // FIX: use _floorTick for lower and _ceilTick for upper.
        uint160 sqrtAtPriceLower = uint160(sqrtU256(2000 * 1e8) * (1 << 96) / 1e10);
        uint160 sqrtAtPriceUpper = uint160(sqrtU256(2500 * 1e8) * (1 << 96) / 1e10);
        int24 rawLower = getTickFromSqrtPrice(sqrtAtPriceLower);
        int24 rawUpper = getTickFromSqrtPrice(sqrtAtPriceUpper);
        int24 tickLower = _floorTick(rawLower, TICK_SPACING);
        int24 tickUpper = _ceilTick(rawUpper, TICK_SPACING);
        console.log("[6] tickLower (~$2000):"); console.logInt(int256(tickLower));
        console.log("[6] tickUpper (~$2500):"); console.logInt(int256(tickUpper));

        // Warn if current price is outside range (single-sided deposit)
        if (actualTick <= tickLower) {
            console.log("[6] WARN: price below range - position will be 100% WETH");
        } else if (actualTick >= tickUpper) {
            console.log("[6] WARN: price above range - position will be 100% USDT");
        }

        uint160 sqrtLower   = getSqrtRatioAtTick(tickLower);
        uint160 sqrtCurrent = actualSqrtPrice;
        uint160 sqrtUpper   = getSqrtRatioAtTick(tickUpper);

        // ── 7. Compute liquidity for ~$100 total ──
        uint256 Q96 = 2**96;

        // Clamp sqrtCurrent to [sqrtLower, sqrtUpper] for out-of-range math
        uint160 sqrtForCalc = sqrtCurrent;
        if (sqrtForCalc < sqrtLower) sqrtForCalc = sqrtLower;
        if (sqrtForCalc > sqrtUpper) sqrtForCalc = sqrtUpper;

        uint256 targetUSDT = 58_490_000;                          // ~$58.49 USDT (6 dec)
        uint256 targetWETH = (41_510_000 * 1e20) / ethPriceUSD8; // ~$41.51 WETH (18 dec)

        uint128 liquidityFromWETH;
        uint128 liquidityFromUSDT;

        if (sqrtUpper > sqrtForCalc) {
            liquidityFromWETH = uint128(
                (targetWETH * uint256(sqrtForCalc) * uint256(sqrtUpper)) /
                (Q96 * (uint256(sqrtUpper) - uint256(sqrtForCalc)))
            );
        } else {
            liquidityFromWETH = type(uint128).max;
        }

        if (sqrtForCalc > sqrtLower) {
            liquidityFromUSDT = uint128(
                (targetUSDT * Q96) / (uint256(sqrtForCalc) - uint256(sqrtLower))
            );
        } else {
            liquidityFromUSDT = type(uint128).max;
        }

        uint128 liquidityAmount = liquidityFromWETH < liquidityFromUSDT
            ? liquidityFromWETH : liquidityFromUSDT;
        require(liquidityAmount > 0, "Zero liquidity computed");
        console.log("[7] liquidityFromWETH:", liquidityFromWETH);
        console.log("[7] liquidityFromUSDT:", liquidityFromUSDT);
        console.log("[7] Using liquidity:  ", liquidityAmount);

        // ── 8. Compute max token amounts (+5% slippage buffer) ──
        uint256 amount0Max;
        uint256 amount1Max;

        if (sqrtCurrent > sqrtLower && sqrtCurrent < sqrtUpper) {
            // In-range: both tokens
            amount0Max = (uint256(liquidityAmount) * Q96 *
                (uint256(sqrtUpper) - uint256(sqrtCurrent))) /
                (uint256(sqrtCurrent) * uint256(sqrtUpper));
            amount1Max = (uint256(liquidityAmount) *
                (uint256(sqrtCurrent) - uint256(sqrtLower))) / Q96;
        } else if (sqrtCurrent <= sqrtLower) {
            // Below range: only WETH
            amount0Max = (uint256(liquidityAmount) * Q96 *
                (uint256(sqrtUpper) - uint256(sqrtLower))) /
                (uint256(sqrtLower) * uint256(sqrtUpper));
            amount1Max = 0;
        } else {
            // Above range: only USDT
            amount0Max = 0;
            amount1Max = (uint256(liquidityAmount) *
                (uint256(sqrtUpper) - uint256(sqrtLower))) / Q96;
        }

        amount0Max = amount0Max * 105 / 100;
        amount1Max = amount1Max * 105 / 100;
        console.log("[8] amount0Max (WETH):", amount0Max);
        console.log("[8] amount1Max (USDT):", amount1Max);

        if (amount0Max > 0) require(tokenA.balanceOf(deployer) >= amount0Max, "Not enough WETH");
        if (amount1Max > 0) require(tokenB.balanceOf(deployer) >= amount1Max, "Not enough USDT");

        // ── 9. Approve tokens ──
        console.log("[9] Approving tokens...");
        _safeApproveUSDT(address(tokenA), PERMIT2, deployer);
        _safeApproveUSDT(address(tokenB), PERMIT2, deployer);

        IAllowanceTransfer(PERMIT2).approve(
            address(tokenA), POSITION_MANAGER, type(uint160).max, type(uint48).max
        );
        IAllowanceTransfer(PERMIT2).approve(
            address(tokenB), POSITION_MANAGER, type(uint160).max, type(uint48).max
        );

        // ── 10. Mint LP position ──
        console.log("[10] Minting LP position...");

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidityAmount),
            uint128(amount0Max),
            uint128(amount1Max),
            deployer,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);

        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);

        console.log("[10] LP position minted!");
        console.log("[10] Next tokenId:", pm.nextTokenId());

        vm.stopBroadcast();

        console.log("\n=== DONE ===");
        console.log("Pool: WETH/USDT 0.30% v4 (no hook), range $2000-$2500");
    }

    // ── Tick alignment helpers ──

    /// @dev Floor tick DOWN to nearest multiple of spacing.
    /// Solidity truncates toward zero, so for negatives we must subtract 1
    /// after division when there's a remainder - otherwise -69423/58 = -1197
    /// instead of the correct floor -1198.
    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @dev Ceil tick UP to nearest multiple of spacing.
    function _ceilTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 floored = _floorTick(tick, spacing);
        if (floored == tick) return tick;
        return floored + spacing;
    }

    // ── Token approval helpers ──

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
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

    // ── Math helpers ──

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
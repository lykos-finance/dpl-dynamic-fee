// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
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
    function decimals() external view returns (uint8);
}

/**
 * @title InitPool
 * @notice Создаёт V4 пул WETH/USDT, инициализирует цену по Chainlink ETH/USD,
 *         минтит LP-позицию в диапазоне ~$2000-$2500 на ~$100 ликвидности.
 *
 * Математика sqrtPriceX96:
 *   В Uniswap V3/V4: sqrtPriceX96 = sqrt(price) * 2^96,
 *   где price = amount1 / amount0 в наименьших единицах токенов (wei).
 *
 *   Для пары WETH(18)/USDT(6) при цене ETH = P USD:
 *     amount1 (USDT, 6 dec) / amount0 (WETH, 18 dec)
 *     = (P * 1e6) / 1e18 = P / 1e12
 *
 *   Если P задан как Chainlink-цена с 8 знаками (ethPriceUSD8 = P * 1e8):
 *     price = ethPriceUSD8 / 1e8 / 1e12 = ethPriceUSD8 / 1e20
 *
 *   sqrtPriceX96 = sqrt(ethPriceUSD8 / 1e20) * 2^96
 *                = sqrt(ethPriceUSD8 * 2^192 / 1e20)
 */
contract InitPool is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ── Mainnet addresses ──
    address constant POOL_MANAGER      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER  = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2           = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH              = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT              = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // ── Pool params ──
    uint24  constant FEE          = 0x800000;     // dynamic fee flag (требует поддержки в хуке!)
    int24   constant TICK_SPACING = 60;
    uint256 constant Q96          = 1 << 96;

    // ── Liquidity targets (~$7 total) ──
    uint256 constant TARGET_USD_WETH_E8 = 3_50 * 1e6;  // $3.50 with 8 decimals
    uint256 constant TARGET_USDT_E6     = 3_50 * 1e4;  // $3.50 in USDT (6 dec)

    // ── Range bounds ──
    uint256 constant PRICE_LOWER_USD8 = 2000 * 1e8;
    uint256 constant PRICE_UPPER_USD8 = 2500 * 1e8;

    // Stale Chainlink guard (1 hour for ETH/USD heartbeat)
    uint256 constant MAX_STALENESS = 3600;

    function run() public {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address hookAddr = vm.envAddress("HOOK_ADDRESS_V5");
        address deployer = vm.addr(pk);

        console.log("=== InitPool ===");
        console.log("Deployer:", deployer);
        console.log("Hook:", hookAddr);

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        IPositionManager pm  = IPositionManager(POSITION_MANAGER);

        // ── 1. Sort tokens (token0 < token1) ──
        // 0xC02a... (WETH) < 0xdAC1... (USDT) → WETH = token0, USDT = token1
        IERC20Like tokenA = IERC20Like(WETH);
        IERC20Like tokenB = IERC20Like(USDT);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        require(address(tokenA) == WETH, "Expected WETH as token0");
        console.log("[1] token0:", tokenA.symbol(), address(tokenA));
        console.log("[1] token1:", tokenB.symbol(), address(tokenB));

        // ── 2. Chainlink price ──
        (, int256 ethAnswer, , uint256 updatedAt, ) =
            AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        require(ethAnswer > 0, "Chainlink: invalid price");
        require(block.timestamp - updatedAt <= MAX_STALENESS, "Chainlink: stale price");
        uint256 ethPriceUSD8 = uint256(ethAnswer);
        console.log("[2] ETH price (USD * 1e8):", ethPriceUSD8);

        // ── 3. Compute startSqrtPrice, align to tickSpacing ──
        uint160 startSqrtPrice = _priceUSD8ToSqrtX96(ethPriceUSD8);
        int24 currentTick = getTickFromSqrtPrice(startSqrtPrice);
        currentTick = _floorToSpacing(currentTick, TICK_SPACING);
        startSqrtPrice = getSqrtRatioAtTick(currentTick);
        console.log("[3] startSqrtPriceX96:", uint256(startSqrtPrice));
        console.log("[3] currentTick:");
        console.logInt(int256(currentTick));

        // ── 4. Tick range $2000 ... $2500 ──
        uint160 sqrtAtLower = _priceUSD8ToSqrtX96(PRICE_LOWER_USD8);
        uint160 sqrtAtUpper = _priceUSD8ToSqrtX96(PRICE_UPPER_USD8);
        int24 rawLower = getTickFromSqrtPrice(sqrtAtLower);
        int24 rawUpper = getTickFromSqrtPrice(sqrtAtUpper);

        // Округляем границы НАРУЖУ (расширяем диапазон)
        int24 tickLower = _floorToSpacing(rawLower, TICK_SPACING);
        int24 tickUpper = _ceilToSpacing(rawUpper, TICK_SPACING);

        require(tickLower < currentTick && currentTick < tickUpper, "Current tick outside range");
        console.log("[4] tickLower (~$2000):");
        console.logInt(int256(tickLower));
        console.log("[4] tickUpper (~$2500):");
        console.logInt(int256(tickUpper));

        uint160 sqrtLower   = getSqrtRatioAtTick(tickLower);
        uint160 sqrtCurrent = startSqrtPrice;
        uint160 sqrtUpper   = getSqrtRatioAtTick(tickUpper);

        // ── 5. Compute liquidity from target amounts ──
        // target WETH (wei): $41.51 / price_USD * 1e18
        //   = (TARGET_USD_WETH_E8 * 1e18) / ethPriceUSD8
        uint256 targetWETH = (TARGET_USD_WETH_E8 * 1e18) / ethPriceUSD8;
        uint256 targetUSDT = TARGET_USDT_E6;
        console.log("[5] targetWETH (wei):", targetWETH);
        console.log("[5] targetUSDT (6dec):", targetUSDT);

        // amount0 → L: L = amount0 * (sqrtCurrent * sqrtUpper / Q96) / (sqrtUpper - sqrtCurrent)
        uint128 liquidityFromWETH = uint128(
            (targetWETH * _mulDiv(uint256(sqrtCurrent), uint256(sqrtUpper), Q96)) /
            (uint256(sqrtUpper) - uint256(sqrtCurrent))
        );
        // amount1 → L: L = amount1 * Q96 / (sqrtCurrent - sqrtLower)
        uint128 liquidityFromUSDT = uint128(
            (targetUSDT * Q96) / (uint256(sqrtCurrent) - uint256(sqrtLower))
        );
        uint128 liquidityAmount = liquidityFromWETH < liquidityFromUSDT
            ? liquidityFromWETH : liquidityFromUSDT;
        console.log("[5] L from WETH:", liquidityFromWETH);
        console.log("[5] L from USDT:", liquidityFromUSDT);
        console.log("[5] L final:", liquidityAmount);
        require(liquidityAmount > 0, "Zero liquidity");

        // ── 6. Required amounts from L (+5% slippage buffer) ──
        // amount0 = L * (sqrtUpper - sqrtCurrent) * Q96 / (sqrtCurrent * sqrtUpper)
        uint256 amount0Max = _mulDiv(
            uint256(liquidityAmount) * (uint256(sqrtUpper) - uint256(sqrtCurrent)),
            Q96,
            uint256(sqrtCurrent) * uint256(sqrtUpper) / Q96  // избегаем overflow
        );
        // Точнее: amount0 = L * (sqrtU - sqrtC) / (sqrtC * sqrtU / Q96)
        amount0Max = (uint256(liquidityAmount) * (uint256(sqrtUpper) - uint256(sqrtCurrent)) * Q96)
                     / (uint256(sqrtCurrent) * uint256(sqrtUpper) / Q96) / Q96;
        // ↑ Запутанно — используем безопасный mulDiv:
        amount0Max = _getAmount0ForLiquidity(sqrtCurrent, sqrtUpper, liquidityAmount);
        uint256 amount1Max = _getAmount1ForLiquidity(sqrtLower, sqrtCurrent, liquidityAmount);

        amount0Max = amount0Max * 105 / 100;
        amount1Max = amount1Max * 105 / 100;

        console.log("[6] amount0Max (WETH wei):", amount0Max);
        console.log("[6] amount1Max (USDT 6dec):", amount1Max);

        require(tokenA.balanceOf(deployer) >= amount0Max, "Not enough token0 (WETH)");
        require(tokenB.balanceOf(deployer) >= amount1Max, "Not enough token1 (USDT)");

        // ── 7. PoolKey ──
        PoolKey memory key = PoolKey(
            Currency.wrap(address(tokenA)),
            Currency.wrap(address(tokenB)),
            FEE,
            TICK_SPACING,
            IHooks(hookAddr)
        );
        PoolId poolId = key.toId();
        console.log("[7] PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));

        // ════════════════════════════════════════════════════════════════════
        vm.startBroadcast(pk);

        // ── 8. Initialize pool ──
        console.log("[8] Initializing pool...");
        manager.initialize(key, startSqrtPrice);
        console.log("[8] Pool initialized");

        // ── 9. Approve: token → Permit2 → PositionManager ──
        console.log("[9] Approving tokens to Permit2...");
        _safeApproveUSDT(address(tokenA), PERMIT2, deployer);
        _safeApproveUSDT(address(tokenB), PERMIT2, deployer);

        console.log("[9] Approving PositionManager via Permit2...");
        IAllowanceTransfer(PERMIT2).approve(
            address(tokenA), POSITION_MANAGER, type(uint160).max, type(uint48).max
        );
        IAllowanceTransfer(PERMIT2).approve(
            address(tokenB), POSITION_MANAGER, type(uint160).max, type(uint48).max
        );
        console.log("[9] Approvals OK");

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

        bytes memory unlockData = abi.encode(actions, params);
        uint256 deadline = block.timestamp + 300;
        pm.modifyLiquidities(unlockData, deadline);

        console.log("[10] LP position minted (NFT visible on Uniswap UI)");
        console.log("[10] Next tokenId:", pm.nextTokenId());

        vm.stopBroadcast();

        console.log("\n=== DONE ===");
        console.log("Pool created + LP position minted as NFT.");
        console.log("Check: app.uniswap.org, revert.finance, Zapper");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Math helpers
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Конвертирует цену ETH в USD (с 8 знаками) в sqrtPriceX96.
     *         Предполагает WETH=token0(18 dec), USDT=token1(6 dec).
     *
     *   price = (priceUSD8 / 1e8) * 1e6 / 1e18 = priceUSD8 / 1e20
     *   sqrtPriceX96 = sqrt(price) * 2^96 = sqrt(price * 2^192)
     *                = sqrt(priceUSD8 * 2^192 / 1e20)
     */
    function _priceUSD8ToSqrtX96(uint256 priceUSD8) internal pure returns (uint160) {
        // priceUSD8 ~ 2e11 (для $2000), priceUSD8 << 192 спокойно влезает в uint256
        // т.к. 2e11 * 2^192 ≈ 1.3e69 < 2^256 ≈ 1.16e77
        uint256 ratioX192 = (priceUSD8 << 192) / 1e20;
        uint256 sqrtX96 = sqrtU256(ratioX192);
        require(sqrtX96 <= type(uint160).max, "sqrtPrice overflow");
        return uint160(sqrtX96);
    }

    /// @notice Округление вниз к ближайшему кратному spacing (для отрицательных — к более отрицательному).
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q -= 1;
        return q * spacing;
    }

    /// @notice Округление вверх к ближайшему кратному spacing.
    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        if (tick > 0 && tick % spacing != 0) q += 1;
        return q * spacing;
    }

    /// @notice amount0 = L * (sqrtB - sqrtA) * Q96 / (sqrtA * sqrtB)
    function _getAmount0ForLiquidity(
        uint160 sqrtA,
        uint160 sqrtB,
        uint128 liquidity
    ) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 numerator1 = uint256(liquidity) << 96;
        uint256 numerator2 = uint256(sqrtB) - uint256(sqrtA);
        // (L<<96) * (sqrtB-sqrtA) / sqrtB / sqrtA
        return _mulDiv(numerator1, numerator2, sqrtB) / sqrtA;
    }

    /// @notice amount1 = L * (sqrtB - sqrtA) / Q96
    function _getAmount1ForLiquidity(
        uint160 sqrtA,
        uint160 sqrtB,
        uint128 liquidity
    ) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _mulDiv(uint256(liquidity), uint256(sqrtB) - uint256(sqrtA), Q96);
    }

    /// @notice Простая версия mulDiv без full-precision; для наших чисел overflow не достижим.
    ///         Для критических операций лучше FullMath.mulDiv из v4-core.
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        require(denominator > 0, "div by zero");
        // если a*b не переполняется — используем обычное умножение
        if (a == 0 || b == 0) return 0;
        unchecked {
            uint256 prod = a * b;
            if (prod / a == b) return prod / denominator;
        }
        // fallback: ((a / d) * b) + ((a % d) * b) / d — теряет точность, но не overflow
        return (a / denominator) * b + ((a % denominator) * b) / denominator;
    }

    function sqrtU256(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    function getTickFromSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        int24 lo = -887272; int24 hi = 887272;
        while (lo < hi) {
            int24 mid = lo + (hi - lo + 1) / 2;
            if (getSqrtRatioAtTick(mid) <= sqrtPriceX96) lo = mid; else hi = mid - 1;
        }
        tick = lo;
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

    // ═══════════════════════════════════════════════════════════════════════
    // ERC20 approve helpers (USDT-safe)
    // ═══════════════════════════════════════════════════════════════════════

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
        if (current != 0) {
            _safeApprove(token, spender, 0);
        }
        _safeApprove(token, spender, type(uint256).max);
    }
}
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
 * @notice Создаёт V4 пул WETH/USDC, инициализирует цену по Chainlink ETH/USD,
 *         минтит LP-позицию в диапазоне ~$2000-$2500 на ~$7 ликвидности.
 *
 * Математика sqrtPriceX96:
 *   В Uniswap V3/V4: sqrtPriceX96 = sqrt(price) * 2^96,
 *   где price = amount1 / amount0 в наименьших единицах токенов (wei).
 *
 *   Для пары WETH(18)/USDC(6) при цене ETH = P USD:
 *     amount1 (USDC, 6 dec) / amount0 (WETH, 18 dec)
 *     = (P * 1e6) / 1e18 = P / 1e12
 *
 *   Если P задан как Chainlink-цена с 8 знаками (ethPriceUSD8 = P * 1e8):
 *     price = ethPriceUSD8 / 1e8 / 1e12 = ethPriceUSD8 / 1e20
 *
 *   sqrtPriceX96 = sqrt(price) * 2^96 = sqrt(price * 2^192)
 *               = sqrt(ethPriceUSD8 * 2^192 / 1e20)
 *
 * Сортировка токенов:
 *   WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
 *   USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
 *   0xA0b8... < 0xC02a... → USDC = token0, WETH = token1
 *
 *   ВНИМАНИЕ: порядок токенов ИНВЕРТИРОВАН относительно версии с USDT!
 *   USDC < WETH → USDC = token0 (6 dec), WETH = token1 (18 dec)
 *
 *   Новая формула price для пула USDC/WETH:
 *     price = amount1 / amount0 = (WETH wei) / (USDC units)
 *           = (1e18) / (P * 1e6) = 1e12 / P
 *
 *   При P заданном как priceUSD8 (= P * 1e8):
 *     price = 1e12 / (priceUSD8 / 1e8) = 1e20 / priceUSD8
 *
 *   sqrtPriceX96 = sqrt(1e20 / priceUSD8) * 2^96
 *               = sqrt(1e20 * 2^192 / priceUSD8)
 */
contract InitPool is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ── Mainnet addresses ──
    address constant POOL_MANAGER      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER  = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2           = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH              = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC              = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // ── Pool params ──
    uint24  constant FEE          = 0x800000;     // dynamic fee flag
    int24   constant TICK_SPACING = 60;
    uint256 constant Q96          = 1 << 96;

    // ── Liquidity targets (~$7 total) ──
    // token0 = USDC (6 dec), token1 = WETH (18 dec)
    uint256 constant TARGET_USDC_E6     = 3_50 * 1e4;  // $3.50 in USDC (6 dec) = 350_000
    uint256 constant TARGET_USD_WETH_E8 = 3_50 * 1e6;  // $3.50 worth of WETH (8 dec precision)

    // ── Range bounds ──
    uint256 constant PRICE_LOWER_USD8 = 2000 * 1e8;
    uint256 constant PRICE_UPPER_USD8 = 2500 * 1e8;

    // Stale Chainlink guard (1 hour for ETH/USD heartbeat)
    uint256 constant MAX_STALENESS = 3600;

    function run() public {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address hookAddr = vm.envAddress("HOOK_ADDRESS_V5");
        address deployer = vm.addr(pk);

        console.log("=== InitPool (USDC/WETH) ===");
        console.log("Deployer:", deployer);
        console.log("Hook:", hookAddr);

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        IPositionManager pm  = IPositionManager(POSITION_MANAGER);

        // ── 1. Sort tokens (token0 < token1) ──
        // 0xA0b8... (USDC) < 0xC02a... (WETH) → USDC = token0, WETH = token1
        IERC20Like token0 = IERC20Like(USDC);
        IERC20Like token1 = IERC20Like(WETH);
        require(address(token0) < address(token1), "Token sort invariant violated");
        console.log("[1] token0:", token0.symbol(), address(token0));
        console.log("[1] token1:", token1.symbol(), address(token1));

        // ── 2. Chainlink price ──
        (, int256 ethAnswer, , uint256 updatedAt, ) =
            AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        require(ethAnswer > 0, "Chainlink: invalid price");
        require(block.timestamp - updatedAt <= MAX_STALENESS, "Chainlink: stale price");
        uint256 ethPriceUSD8 = uint256(ethAnswer);
        console.log("[2] ETH price (USD * 1e8):", ethPriceUSD8);

        // ── 3. Compute startSqrtPrice for USDC/WETH pool ──
        // price = WETH/USDC = 1e20 / priceUSD8
        // (USDC is token0, so price = amount1/amount0 = WETH_wei / USDC_units)
        uint160 startSqrtPrice = _priceUSD8ToSqrtX96_USDC_WETH(ethPriceUSD8);
        int24 currentTick = getTickFromSqrtPrice(startSqrtPrice);
        currentTick = _floorToSpacing(currentTick, TICK_SPACING);
        startSqrtPrice = getSqrtRatioAtTick(currentTick);
        console.log("[3] startSqrtPriceX96:", uint256(startSqrtPrice));
        console.log("[3] currentTick:");
        console.logInt(int256(currentTick));

        // ── 4. Tick range $2000 ... $2500 ──
        // Для пула USDC/WETH (инвертированный): lower price в USD → upper tick, и наоборот
        // Tick растёт с ростом price = WETH/USDC, т.е. с падением USD-цены ETH
        // $2500 (ETH дороже) → price = 1e20/2500e8 (меньше) → tick ниже (tickLower)
        // $2000 (ETH дешевле) → price = 1e20/2000e8 (больше) → tick выше (tickUpper)
        uint160 sqrtAt2500 = _priceUSD8ToSqrtX96_USDC_WETH(PRICE_UPPER_USD8); // $2500 → lower sqrt
        uint160 sqrtAt2000 = _priceUSD8ToSqrtX96_USDC_WETH(PRICE_LOWER_USD8); // $2000 → upper sqrt

        int24 rawLower = getTickFromSqrtPrice(sqrtAt2500); // tick at $2500 (lower price = lower tick)
        int24 rawUpper = getTickFromSqrtPrice(sqrtAt2000); // tick at $2000 (higher price = higher tick)

        // Округляем границы НАРУЖУ (расширяем диапазон)
        int24 tickLower = _floorToSpacing(rawLower, TICK_SPACING);
        int24 tickUpper = _ceilToSpacing(rawUpper, TICK_SPACING);

        require(tickLower < currentTick && currentTick < tickUpper, "Current tick outside range");
        console.log("[4] tickLower (ETH ~$2500, inverted):");
        console.logInt(int256(tickLower));
        console.log("[4] tickUpper (ETH ~$2000, inverted):");
        console.logInt(int256(tickUpper));

        uint160 sqrtLower   = getSqrtRatioAtTick(tickLower);
        uint160 sqrtCurrent = startSqrtPrice;
        uint160 sqrtUpper   = getSqrtRatioAtTick(tickUpper);

        // ── 5. Compute liquidity from target amounts ──
        // token0 = USDC (6 dec) → amount0 formula
        // token1 = WETH (18 dec) → amount1 formula
        uint256 targetUSDC = TARGET_USDC_E6;
        uint256 targetWETH = (TARGET_USD_WETH_E8 * 1e18) / ethPriceUSD8;
        console.log("[5] targetUSDC (6dec):", targetUSDC);
        console.log("[5] targetWETH (wei):",  targetWETH);

        // amount0 (USDC) → L: L = amount0 * (sqrtCurrent * sqrtUpper / Q96) / (sqrtUpper - sqrtCurrent)
        uint128 liquidityFromUSDC = uint128(
            (targetUSDC * _mulDiv(uint256(sqrtCurrent), uint256(sqrtUpper), Q96)) /
            (uint256(sqrtUpper) - uint256(sqrtCurrent))
        );
        // amount1 (WETH) → L: L = amount1 * Q96 / (sqrtCurrent - sqrtLower)
        uint128 liquidityFromWETH = uint128(
            (targetWETH * Q96) / (uint256(sqrtCurrent) - uint256(sqrtLower))
        );
        uint128 liquidityAmount = liquidityFromUSDC < liquidityFromWETH
            ? liquidityFromUSDC : liquidityFromWETH;
        console.log("[5] L from USDC:", liquidityFromUSDC);
        console.log("[5] L from WETH:", liquidityFromWETH);
        console.log("[5] L final:", liquidityAmount);
        require(liquidityAmount > 0, "Zero liquidity");

        // ── 6. Required amounts from L (+5% slippage buffer) ──
        // amount0 (USDC) = L * (sqrtUpper - sqrtCurrent) * Q96 / (sqrtCurrent * sqrtUpper)
        uint256 amount0Max = _getAmount0ForLiquidity(sqrtCurrent, sqrtUpper, liquidityAmount);
        // amount1 (WETH) = L * (sqrtCurrent - sqrtLower) / Q96
        uint256 amount1Max = _getAmount1ForLiquidity(sqrtLower, sqrtCurrent, liquidityAmount);

        amount0Max = amount0Max * 105 / 100;
        amount1Max = amount1Max * 105 / 100;

        console.log("[6] amount0Max (USDC 6dec):", amount0Max);
        console.log("[6] amount1Max (WETH wei):",  amount1Max);

        require(token0.balanceOf(deployer) >= amount0Max, "Not enough token0 (USDC)");
        require(token1.balanceOf(deployer) >= amount1Max, "Not enough token1 (WETH)");

        // ── 7. PoolKey ──
        PoolKey memory key = PoolKey(
            Currency.wrap(address(token0)),  // USDC
            Currency.wrap(address(token1)),  // WETH
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
        // USDC — стандартный ERC20, не требует сброса allowance перед approve
        console.log("[9] Approving tokens to Permit2...");
        _safeApprove(address(token0), PERMIT2, type(uint256).max);  // USDC
        _safeApprove(address(token1), PERMIT2, type(uint256).max);  // WETH

        console.log("[9] Approving PositionManager via Permit2...");
        IAllowanceTransfer(PERMIT2).approve(
            address(token0), POSITION_MANAGER, type(uint160).max, type(uint48).max
        );
        IAllowanceTransfer(PERMIT2).approve(
            address(token1), POSITION_MANAGER, type(uint160).max, type(uint48).max
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
        params[1] = abi.encode(key.currency0);  // USDC
        params[2] = abi.encode(key.currency1);  // WETH

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
     * @notice Конвертирует цену ETH в USD (8 знаков) в sqrtPriceX96 для пула USDC/WETH.
     *
     *   token0 = USDC (6 dec), token1 = WETH (18 dec)
     *   price = amount1 / amount0 = WETH_wei / USDC_units
     *         = 1e18 / (priceUSD * 1e6)
     *         = 1e12 / priceUSD
     *
     *   Подставляем priceUSD = priceUSD8 / 1e8:
     *     price = 1e12 / (priceUSD8 / 1e8) = 1e20 / priceUSD8
     *
     *   sqrtPriceX96 = sqrt(price) * 2^96
     *               = sqrt(1e20 / priceUSD8 * 2^192)
     *               = sqrt(1e20 * 2^192 / priceUSD8)
     */
    function _priceUSD8ToSqrtX96_USDC_WETH(uint256 priceUSD8) internal pure returns (uint160) {
        require(priceUSD8 > 0, "price must be > 0");
        // 1e20 * 2^192 / priceUSD8
        // 1e20 * 2^192 ≈ 6.3e77 → превышает uint256 (max ~1.16e77)
        // Используем: sqrt(1e20/priceUSD8) * 2^96
        // Разобьём: sqrt(1e20 * 2^192 / priceUSD8) = sqrt(1e20/priceUSD8) * 2^96
        // Чтобы не терять точность при делении до sqrt, применим трюк:
        // sqrt(A/B) * 2^96 = sqrt(A * 2^192 / B)
        // Вычисляем A * 2^64 / B сначала, потом умножаем на 2^128 внутри sqrt:
        // ratioX192 = (1e20 << 192) / priceUSD8  — переполнение!
        //
        // Безопасный способ: разложим на два множителя
        // sqrt(1e20 / priceUSD8) * 2^96
        // = sqrt(1e20) * 2^96 / sqrt(priceUSD8)
        // Но sqrt(1e20) = 1e10, sqrt(priceUSD8) — дробное.
        //
        // Лучший способ: работаем с ratioX128 = (1e20 << 128) / priceUSD8, затем sqrt даст X64,
        // домножаем на 2^32, получим X96.
        //
        // (1e20 << 128) / priceUSD8:
        //   1e20 = ~3.4e19 < 2^66; <<128 → ~2^194 → переполнение uint256.
        //
        // Итоговый рабочий подход: вычитаем степень двойки поэтапно.
        // ratioX96_sq = (1e20 << 96) / priceUSD8  → это (price * 2^96), но нам нужен sqrt.
        // Фактически нам нужен sqrt(price * 2^192).
        // price * 2^192 = 1e20 / priceUSD8 * 2^192
        // Разложим: сначала вычислим 2^192 / priceUSD8, затем умножим на 1e20.
        // 2^192 / priceUSD8 ≈ 2^192 / 2e11 ≈ 2^181 — влезает в uint256.
        uint256 inv = (type(uint256).max / priceUSD8); // ≈ 2^256 / priceUSD8
        // Нам нужно 1e20 * 2^192 / priceUSD8.
        // Сделаем: ratioX192 = (1e20 * (2^192 / priceUSD8)) с корректировкой:
        // Но прямое умножение 1e20 * inv тоже может переполниться.
        //
        // Финальный подход: делим пространство пополам через промежуточный X96.
        // price_X192 = (1e20 << 64) / priceUSD8 даёт нам price * 2^64 (без переполнения):
        //   1e20 << 64 ≈ 1.8e39 < 2^256 ✓
        //   Делим на priceUSD8 ~ 2e11 → результат ~ 9e27, то есть < 2^93 ✓
        // Домножаем на 2^128 → получаем price * 2^192:
        //   9e27 * 2^128 ≈ 3e66 < 2^222 ✓
        uint256 priceX192 = ((1e20 << 64) / priceUSD8) << 128;
        uint256 sqrtX96 = sqrtU256(priceX192);
        require(sqrtX96 <= type(uint160).max, "sqrtPrice overflow");
        return uint160(sqrtX96);
    }

    /**
     * @notice Конвертирует цену ETH в USD (8 знаков) в sqrtPriceX96 для пула WETH/USDC.
     *         Используется только если WETH < USDC по адресу (для других сетей).
     *         На mainnet USDC < WETH, поэтому используется _priceUSD8ToSqrtX96_USDC_WETH.
     *
     *   price = USDC_units / WETH_wei = priceUSD * 1e6 / 1e18 = priceUSD / 1e12
     *         = priceUSD8 / 1e8 / 1e12 = priceUSD8 / 1e20
     *
     *   ratioX192 = priceUSD8 * 2^192 / 1e20
     *   (priceUSD8 ~ 2e11; 2e11 * 2^192 ≈ 1.3e69 < 2^256 ✓)
     */
    function _priceUSD8ToSqrtX96_WETH_USDC(uint256 priceUSD8) internal pure returns (uint160) {
        uint256 ratioX192 = (priceUSD8 << 192) / 1e20;
        uint256 sqrtX96 = sqrtU256(ratioX192);
        require(sqrtX96 <= type(uint160).max, "sqrtPrice overflow");
        return uint160(sqrtX96);
    }

    /// @notice Округление вниз к ближайшему кратному spacing.
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

    /// @notice mulDiv без full-precision; для критических операций использовать FullMath.mulDiv.
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        require(denominator > 0, "div by zero");
        if (a == 0 || b == 0) return 0;
        unchecked {
            uint256 prod = a * b;
            if (prod / a == b) return prod / denominator;
        }
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
    // ERC20 approve helpers
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Стандартный safe approve (USDC — полноценный ERC20, не требует
     *         сброса в 0 перед новым approve, в отличие от USDT).
     */
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }
}
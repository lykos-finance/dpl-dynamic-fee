// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {VolatilityGuardHookV2} from "../src/VolatilityGuardHookV2.sol";
import {RobustRouterV6} from "../src/RobustRouterV6.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function symbol() external view returns (string memory);
}

contract HookFactory {
    function deploy(bytes memory code, bytes32 salt) public returns (address addr) {
        assembly { addr := create2(0, add(code, 0x20), mload(code), salt) }
        require(addr != address(0), "Factory failed");
    }
}

contract FullEndToEnd is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH         = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT         = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() public {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(deployer);

        IPoolManager manager = IPoolManager(POOL_MANAGER);

        // ── 1. Deploy factory + hook ──
        HookFactory factory = new HookFactory();
        bytes memory code = abi.encodePacked(
            type(VolatilityGuardHookV2).creationCode,
            abi.encode(POOL_MANAGER)
        );

        vm.pauseGasMetering();
        uint160 target  = uint160(Hooks.BEFORE_SWAP_FLAG);
        uint160 mask    = 0x3FFF;
        uint256 saltInt = uint256(keccak256(abi.encodePacked(deployer, block.timestamp)));
        address hookAddress;
        for (uint256 i = 0; i < 500_000; i++) {
            bytes32 salt = bytes32(saltInt + i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)));
            address addr = address(uint160(uint256(hash)));
            if ((uint160(addr) & mask) == target) { hookAddress = addr; saltInt += i; break; }
        }
        vm.resumeGasMetering();
        require(hookAddress != address(0), "Hook mining failed");
        console.log("[1] Hook deployed:", hookAddress);
        console.log("[1] Hook permission bits (expect BEFORE_SWAP=0x80=128):", uint160(hookAddress) & 0x3FFF);
        factory.deploy(code, bytes32(saltInt));
        console.log("[1] Hook creation confirmed via factory");

        // ── 2. Sort tokens ──
        IERC20Like tokenA = IERC20Like(WETH);
        IERC20Like tokenB = IERC20Like(USDT);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        console.log("[2] Token0:", tokenA.symbol(), address(tokenA));
        console.log("[2] Token1:", tokenB.symbol(), address(tokenB));

        // ── 3. Chainlink price ──
        console.log("[3] Reading Chainlink ETH/USD...");
        (, int256 ethAnswer, , uint256 updatedAt, ) = AggregatorV3Interface(
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
        ).latestRoundData();
        require(ethAnswer > 0, "Chainlink: invalid price");
        require(block.timestamp - updatedAt < 3600, "Chainlink: stale price");
        uint256 ethPriceUSD8 = uint256(ethAnswer);
        console.log("[3] ETH/USD (x1e8):", ethPriceUSD8);
        console.log("[3] Price age (sec):", block.timestamp - updatedAt);

        // ── 4. Compute tick + sqrtPrice ──
        uint160 startSqrtPrice = uint160(sqrtU256(ethPriceUSD8) * (1 << 96) / 1e10);
        int24 currentTick = getTickFromSqrtPrice(startSqrtPrice);
        currentTick       = currentTick / 60 * 60;
        startSqrtPrice    = getSqrtRatioAtTick(currentTick);
        console.log("[4] currentTick (snapped):", uint256(int256(currentTick)));
        console.log("[4] startSqrtPriceX96:", startSqrtPrice);

        // ── 5. Deploy RobustRouterV6 ──
        console.log("[5] Deploying RobustRouterV6...");
        RobustRouterV6 router = new RobustRouterV6(manager);
        console.log("[5] Router:", address(router));
        console.log("[5] Router owner:", router.owner());
        require(router.owner() == deployer, "[5] FAIL: router owner != deployer");

        // ── 6. Tick range ≈ ±5% от текущей цены ETH ──
        int24 tickDelta5Pct = 480;
        int24 tickLower = (currentTick - tickDelta5Pct) / 60 * 60;
        int24 tickUpper = (currentTick + tickDelta5Pct) / 60 * 60;

        uint160 sqrtLower   = getSqrtRatioAtTick(tickLower);
        uint160 sqrtCurrent = getSqrtRatioAtTick(currentTick);
        uint160 sqrtUpper   = getSqrtRatioAtTick(tickUpper);

        console.log("[6] tickLower:", uint256(int256(tickLower)));
        console.log("[6] tickUpper:", uint256(int256(tickUpper)));

        // ── 7. Compute liquidity ──
        uint256 Q96 = 2**96;
        uint256 targetUSDT = 1_000_000;                        // 1 USDT (6 decimals)
        uint256 targetWETH = (1_000_000 * 1e20) / ethPriceUSD8; // ~$1 in WETH (18 decimals)

        uint128 liquidityFromUSDT = uint128(
            (targetUSDT * Q96) / (uint256(sqrtUpper) - uint256(sqrtCurrent))
        );
        uint128 liquidityFromWETH = uint128(
            (targetWETH * uint256(sqrtCurrent) * uint256(sqrtLower)) /
            (Q96 * (uint256(sqrtCurrent) - uint256(sqrtLower)))
        );

        uint128 liquidityAmount = liquidityFromWETH < liquidityFromUSDT
            ? liquidityFromWETH : liquidityFromUSDT;
        console.log("[7] Liquidity from USDT:", liquidityFromUSDT);
        console.log("[7] Liquidity from WETH:", liquidityFromWETH);
        console.log("[7] Liquidity (min):", liquidityAmount);
        require(liquidityAmount > 0, "[7] FAIL: liquidityAmount is 0");

        // ── 8. Compute token amounts ──
        uint256 tokenASeed = (uint256(liquidityAmount) * Q96 *
            (uint256(sqrtCurrent) - uint256(sqrtLower))) /
            (uint256(sqrtCurrent) * uint256(sqrtLower));
        uint256 tokenBSeed = (uint256(liquidityAmount) *
            (uint256(sqrtUpper) - uint256(sqrtCurrent))) / Q96;

        tokenASeed = tokenASeed * 101 / 100;
        tokenBSeed = tokenBSeed * 101 / 100;

        console.log("[8] Required token0 (WETH):", tokenASeed);
        console.log("[8] Required token1 (USDT):", tokenBSeed);
        console.log("[8] Deployer token0 balance:", tokenA.balanceOf(deployer));
        console.log("[8] Deployer token1 balance:", tokenB.balanceOf(deployer));

        require(tokenA.balanceOf(deployer) >= tokenASeed, "Not enough token0");
        require(tokenB.balanceOf(deployer) >= tokenBSeed, "Not enough token1");
        console.log("[8] Balance check OK");

        // ── 9. Approve router ──
        // USDT approve() возвращает void (не bool) → нельзя вызывать через интерфейс.
        // Используем low-level call, который обрабатывает оба варианта.
        console.log("[9] Approving router for token0...");
        _safeApprove(address(tokenA), address(router), type(uint256).max);
        console.log("[9] Approving router for token1...");
        _safeApprove(address(tokenB), address(router), type(uint256).max);
        console.log("[9] Approve OK");

        // ── 10. Initialize pool ──
        console.log("[10] Building PoolKey...");
        console.log("[10]   currency0:", address(tokenA));
        console.log("[10]   currency1:", address(tokenB));
        console.log("[10]   fee (DYNAMIC_FEE_FLAG=0x800000):", uint256(0x800000));
        console.log("[10]   tickSpacing: 60");
        console.log("[10]   hook:", hookAddress);
        PoolKey memory key = PoolKey(
            Currency.wrap(address(tokenA)),
            Currency.wrap(address(tokenB)),
            0x800000, 60, IHooks(hookAddress)
        );
        console.log("[10] Calling manager.initialize()...");
        manager.initialize(key, startSqrtPrice);
        console.log("[10] Pool initialized OK. tick:", uint256(int256(currentTick)));

        // ── 11. Add liquidity ──
        console.log("[11] Calling router.addLiquidity()...");
        console.log("[11]   liquidityDelta:", uint256(liquidityAmount));
        uint256 dl = block.timestamp + 300; // deadline = 5 min
        router.addLiquidity(
            key, tickLower, tickUpper,
            int256(uint256(liquidityAmount)),
            tokenASeed,   // amount0Max
            tokenBSeed,   // amount1Max
            dl
        );
        console.log("[11] addLiquidity OK");
        console.log("[11]   Deployer token0 after:", tokenA.balanceOf(deployer));
        console.log("[11]   Deployer token1 after:", tokenB.balanceOf(deployer));

        // ── 12. Swap 1 (10% от WETH баланса — большой свап для триггера PanicMode) ──
        uint256 swapIn = tokenA.balanceOf(deployer) / 10; // 10% от баланса
        console.log("[12] Swap 1 (zeroForOne=true), amount:", swapIn);
        router.swap(
            key,
            true,                              // zeroForOne
            -int256(swapIn),                   // exact input
            TickMath.MIN_SQRT_PRICE + 1,       // sqrtPriceLimitX96
            0,                                 // amountOutMin (тест, не production)
            dl
        );
        console.log("[12] Swap 1 OK");
        console.log("[12]   Deployer token0 after:", tokenA.balanceOf(deployer));
        console.log("[12]   Deployer token1 after:", tokenB.balanceOf(deployer));
        _logPanicState(hookAddress, key, "[12]");

        // ── 13. Swap 2 (try/catch) ──
        uint256 swapIn2 = tokenA.balanceOf(deployer) / 10;
        console.log("[13] Swap 2 attempt, amount:", swapIn2);
        try router.swap(
            key,
            true,
            -int256(swapIn2),
            TickMath.MIN_SQRT_PRICE + 1,
            0,
            dl
        ) {
            console.log("[13] Swap 2 OK");
            console.log("[13]   Deployer token0 after:", tokenA.balanceOf(deployer));
            console.log("[13]   Deployer token1 after:", tokenB.balanceOf(deployer));
        } catch (bytes memory err) {
            console.log("[13] Swap 2 blocked. err bytes:");
            console.logBytes(err);
        }
        _logPanicState(hookAddress, key, "[13]");

        // ── 14. Remove liquidity ──
        console.log("[14] Calling router.removeLiquidity()...");
        uint256 bA = tokenA.balanceOf(deployer);
        uint256 bB = tokenB.balanceOf(deployer);
        router.removeLiquidity(
            key, tickLower, tickUpper,
            int256(uint256(liquidityAmount)),
            0, 0, // amount0Min, amount1Min (тест, не production)
            dl
        );
        uint256 retA = tokenA.balanceOf(deployer) - bA;
        uint256 retB = tokenB.balanceOf(deployer) - bB;
        console.log("[14] removeLiquidity OK");
        console.log("[14]   Returned token0:", retA);
        console.log("[14]   Returned token1:", retB);
        require(retA > 0 || retB > 0, "FAIL: no tokens returned on remove");
        console.log("[14] PASS: liquidity removed successfully");

        // ── 15. Вывод остатков с роутера (если есть) ──
        uint256 routerA = tokenA.balanceOf(address(router));
        uint256 routerB = tokenB.balanceOf(address(router));
        console.log("[15] Router residuals: token0=", routerA, " token1=", routerB);
        if (routerA > 0) {
            router.withdrawToken(address(tokenA), deployer, routerA);
            console.log("[15] Withdrew token0 from router:", routerA);
        }
        if (routerB > 0) {
            router.withdrawToken(address(tokenB), deployer, routerB);
            console.log("[15] Withdrew token1 from router:", routerB);
        }

        console.log("=== SUCCESS ===");
        vm.stopBroadcast();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

    function _logPanicState(address hookAddr, PoolKey memory key, string memory step) internal view {
        PoolId poolId = key.toId();
        (int24 refTick, uint256 lastUpdate, uint256 panicExpiry, bool isInit) =
            VolatilityGuardHookV2(hookAddr).states(poolId);
        bool panicActive = block.timestamp < panicExpiry;
        uint24 currentFee = panicActive ? uint24(20000) : uint24(500);
        uint256 feePercent100 = uint256(currentFee); // in bps (500 = 0.05%, 20000 = 2.00%)

        console.log(string.concat(step, " PanicMode:"), panicActive ? "ACTIVE" : "inactive");
        console.log(string.concat(step, "   fee (bps):"), feePercent100);
        console.log(string.concat(step, "   referenceTick:"), uint256(int256(refTick)));
        if (panicActive) {
            console.log(string.concat(step, "   panicExpiry:"), panicExpiry);
            console.log(string.concat(step, "   timeLeft (sec):"), panicExpiry - block.timestamp);
        }
    }

    /// @dev Safe approve that works with non-standard tokens (USDT returns void).
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
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

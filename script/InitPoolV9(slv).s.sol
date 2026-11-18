// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {IMulticall_v4} from "v4-periphery/src/interfaces/IMulticall_v4.sol";
import {VolatilityGuardHookV9} from "../src/dynamic-fee(slv-V9).sol";
import {V9Common, IERC20V9} from "./V9Common(slv).sol";

/// @notice Creates a pool with VolatilityGuardHookV9 and mints the first position to the deployer in one
///         transaction. Works for native ETH pools and WETH pools (WETH on either side).
///
/// Env:
///   PRIVATE_KEY, HOOK_ADDRESS_V9
///   TOKEN_ADDRESS        the token paired with ETH
///   USE_WETH             false (default): native ETH. true: WETH, created by the initializer only;
///                        missing WETH is wrapped from the wallet's ETH
///   LP_ETH               ETH side of the position, wei. The token side follows from the price
///   TOKEN_PRICE_ETH      wei per whole token, only for tokens without a live oracle in the hook
///   LP_RANGE_BELOW_PCT / LP_RANGE_ABOVE_PCT   range in the token's price, % (default 50 / 100)
///   LP_FULL_RANGE        true: the whole price range instead (default false)
contract InitPoolV9 is V9Common {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Plan {
        uint160 startSqrtPrice;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 ethMax;
        uint256 tokenMax;
    }

    function run() public virtual {
        _run(vm.envAddress("TOKEN_ADDRESS"), vm.envOr("USE_WETH", false));
    }

    function _run(address token, bool useWeth) internal {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address hook = vm.envAddress("HOOK_ADDRESS_V9");

        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");
        require(hook.code.length != 0, "HOOK_ADDRESS_V9 has no code");
        require(address(VolatilityGuardHookV9(hook).poolManager()) == POOL_MANAGER, "Hook uses another PoolManager");

        Pair memory p = _pair(hook, token, useWeth);
        (uint160 existing,,,) = IPoolManager(POOL_MANAGER).getSlot0(p.key.toId());
        require(existing == 0, "Pool already initialized");

        (uint256 priceE18, bool fromOracle) = _priceE18(hook, p);
        if (useWeth || !fromOracle) {
            require(deployer == VolatilityGuardHookV9(hook).initializer(), "Only the hook's initializer can create this pool");
        }

        console.log("=== InitPoolV9 ===");
        console.log("Deployer:", deployer);
        console.log("Pair:     ETH side", useWeth ? "WETH" : "native ETH", "/", IERC20V9(token).symbol());
        console.log("ETH side is currency0:", p.ethIs0);
        console.log("Price, wei per token:", priceE18, fromOracle ? "(hook oracle)" : "(TOKEN_PRICE_ETH)");
        console.log("Base fee, pips:", VolatilityGuardHookV9(hook).baseFee(token));

        Plan memory plan = _plan(p, priceE18);
        console.log("ETH max (wei):", plan.ethMax);
        console.log("Token max:    ", plan.tokenMax);
        require(IERC20V9(token).balanceOf(deployer) >= plan.tokenMax, "Not enough token");
        if (useWeth) {
            require(IERC20V9(WETH).balanceOf(deployer) + deployer.balance >= plan.ethMax, "Not enough ETH + WETH");
        } else {
            require(deployer.balance >= plan.ethMax, "Not enough ETH");
        }

        bytes[] memory calls = _calls(p, plan, deployer);
        uint256 tokenId = IPositionManager(POSITION_MANAGER).nextTokenId();

        vm.startBroadcast(pk);
        uint48 expiry = uint48(block.timestamp + 3600);
        _approveViaPermit2(token, deployer, POSITION_MANAGER, plan.tokenMax, expiry);
        if (useWeth) {
            _wrapShortfall(deployer, plan.ethMax);
            _approveViaPermit2(WETH, deployer, POSITION_MANAGER, plan.ethMax, expiry);
        }
        IMulticall_v4(POSITION_MANAGER).multicall{value: useWeth ? 0 : plan.ethMax}(calls);
        vm.stopBroadcast();

        console.log("\n=== DONE ===");
        console.log("Position tokenId:", tokenId);
        console.log(string.concat("POOL_ID=", vm.toString(PoolId.unwrap(p.key.toId()))));
        console.log(string.concat("TOKEN_ID=", vm.toString(tokenId)));
    }

    function _plan(Pair memory p, uint256 priceE18) internal view returns (Plan memory plan) {
        uint256 ethAmount = vm.envUint("LP_ETH");
        require(ethAmount > 0, "LP_ETH not set");
        plan.startSqrtPrice = _sqrtFromPrice(p, priceE18);

        if (vm.envOr("LP_FULL_RANGE", false)) {
            plan.tickLower = TickMath.minUsableTick(TICK_SPACING);
            plan.tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        } else {
            uint256 below = vm.envOr("LP_RANGE_BELOW_PCT", uint256(50));
            uint256 above = vm.envOr("LP_RANGE_ABOVE_PCT", uint256(100));
            require(below > 0 && below < 100 && above > 0, "Bad range");
            int24 a = TickMath.getTickAtSqrtPrice(_sqrtFromPrice(p, priceE18 * (100 - below) / 100));
            int24 b = TickMath.getTickAtSqrtPrice(_sqrtFromPrice(p, priceE18 * (100 + above) / 100));
            (int24 lo, int24 hi) = a < b ? (a, b) : (b, a); // the orientation decides which is lower
            plan.tickLower = _floorToSpacing(lo);
            plan.tickUpper = _floorToSpacing(hi) + TICK_SPACING;
        }

        uint256 tokenAmount = FullMath.mulDiv(ethAmount, 10 ** p.decimals, priceE18);
        (uint256 amount0, uint256 amount1) = p.ethIs0 ? (ethAmount, tokenAmount) : (tokenAmount, ethAmount);
        plan.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            plan.startSqrtPrice,
            TickMath.getSqrtPriceAtTick(plan.tickLower),
            TickMath.getSqrtPriceAtTick(plan.tickUpper),
            amount0,
            amount1
        );
        require(plan.liquidity > 0, "Zero liquidity");
        plan.ethMax = (ethAmount * 101) / 100 + 1;
        plan.tokenMax = (tokenAmount * 101) / 100 + 1;
    }

    function _calls(Pair memory p, Plan memory plan, address recipient) internal view returns (bytes[] memory calls) {
        bool native = p.ethSide == address(0);
        bytes memory actions = native
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](native ? 3 : 2);
        (uint256 max0, uint256 max1) = p.ethIs0 ? (plan.ethMax, plan.tokenMax) : (plan.tokenMax, plan.ethMax);
        params[0] = abi.encode(
            p.key, plan.tickLower, plan.tickUpper, uint256(plan.liquidity), uint128(max0), uint128(max1), recipient, bytes("")
        );
        params[1] = abi.encode(p.key.currency0, p.key.currency1);
        if (native) params[2] = abi.encode(p.key.currency0, recipient); // unused ETH back

        calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (p.key, plan.startSqrtPrice));
        calls[1] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp + 300));
    }
}

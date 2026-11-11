// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {IMulticall_v4} from "v4-periphery/src/interfaces/IMulticall_v4.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {VolatilityGuardHookV8} from "../src/dynamic-fee(slv-V8).sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Creates the native ETH/USDC pool with VolatilityGuardHookV8 on Ethereum mainnet and mints
///         the first LP position to the deployer. Both happen in one transaction, so nobody can move
///         the price of the empty pool in between.
///
/// Native ETH is always currency0 and USDC currency1, so a higher ETH price is a higher tick.
contract InitPoolV8 is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ── Mainnet addresses ──
    address constant POOL_MANAGER      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER  = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2           = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC              = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // ── Pool params ──
    int24 constant TICK_SPACING = 60;

    // Stale Chainlink guard (1 hour for ETH/USD heartbeat)
    uint256 constant MAX_STALENESS = 3600;

    struct Position {
        int24   tickLower;
        int24   tickUpper;
        uint160 startSqrtPrice;
        uint128 liquidity;
        uint256 ethMax;
        uint256 usdcMax;
    }

    function run() public {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address hook     = vm.envAddress("HOOK_ADDRESS_V8");

        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");
        require(hook.code.length != 0, "HOOK_ADDRESS_V8 has no code");
        require(address(VolatilityGuardHookV8(hook).poolManager()) == POOL_MANAGER, "Hook uses another PoolManager");

        console.log("=== InitPoolV8 ===");
        console.log("Deployer:", deployer);
        console.log("Hook:    ", hook);

        PoolKey memory key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook)
        );
        (uint160 existingPrice,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        require(existingPrice == 0, "Pool already initialized");

        Position memory position = _planPosition();
        console.log("ETH max (wei):    ", position.ethMax);
        console.log("USDC max (6 dec): ", position.usdcMax);
        require(deployer.balance >= position.ethMax, "Not enough ETH");
        require(IERC20Like(USDC).balanceOf(deployer) >= position.usdcMax, "Not enough USDC");

        bytes[] memory calls = _initAndMintCalls(key, position, deployer);
        uint256 tokenId = IPositionManager(POSITION_MANAGER).nextTokenId();

        vm.startBroadcast(pk);
        _approve(USDC);
        // Unused ETH is swept back to the deployer in the same call
        IMulticall_v4(POSITION_MANAGER).multicall{value: position.ethMax}(calls);
        vm.stopBroadcast();

        console.log("\n=== DONE ===");
        console.log("Position tokenId:", tokenId);
        console.log("\nAdd to .env:");
        console.log(string.concat("POOL_ID_V8=", vm.toString(PoolId.unwrap(key.toId()))));
        console.log(string.concat("TOKEN_ID=", vm.toString(tokenId)));
    }

    function _planPosition() internal view returns (Position memory p) {
        // ── Ликвидность на каждую сторону в USDC (6 знаков), диапазон в % от текущей цены ETH ──
        uint256 usdcAmount = vm.envOr("LP_USDC_PER_SIDE", uint256(2_500_000)); // $2.50
        uint256 rangeBelow = vm.envOr("LP_RANGE_BELOW_PCT", uint256(50));
        uint256 rangeAbove = vm.envOr("LP_RANGE_ABOVE_PCT", uint256(50));
        require(usdcAmount > 0, "Zero liquidity");
        require(rangeBelow > 0 && rangeBelow < 100 && rangeAbove > 0, "Bad range");

        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        require(answer > 0, "Chainlink: invalid price");
        require(block.timestamp - updatedAt <= MAX_STALENESS, "Chainlink: stale price");
        uint256 ethUsd8 = uint256(answer);
        console.log("ETH price (USD * 1e8):", ethUsd8);

        p.startSqrtPrice = _sqrtPriceFromUsd8(ethUsd8);
        p.tickLower = _floorToSpacing(TickMath.getTickAtSqrtPrice(_sqrtPriceFromUsd8(ethUsd8 * (100 - rangeBelow) / 100)));
        p.tickUpper = _floorToSpacing(TickMath.getTickAtSqrtPrice(_sqrtPriceFromUsd8(ethUsd8 * (100 + rangeAbove) / 100)))
            + TICK_SPACING;

        uint256 ethAmount = (usdcAmount * 1e20) / ethUsd8;
        p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            p.startSqrtPrice,
            TickMath.getSqrtPriceAtTick(p.tickLower),
            TickMath.getSqrtPriceAtTick(p.tickUpper),
            ethAmount,
            usdcAmount
        );
        require(p.liquidity > 0, "Zero liquidity");

        // The position takes at most the target amounts, 1% covers rounding
        p.ethMax  = (ethAmount * 101) / 100 + 1;
        p.usdcMax = (usdcAmount * 101) / 100 + 1;
    }

    function _initAndMintCalls(PoolKey memory key, Position memory p, address recipient)
        internal
        view
        returns (bytes[] memory calls)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, p.tickLower, p.tickUpper, uint256(p.liquidity), uint128(p.ethMax), uint128(p.usdcMax), recipient, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, recipient);

        calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (key, p.startSqrtPrice));
        calls[1] = abi.encodeCall(
            IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp + 300)
        );
    }

    /// @dev token → Permit2 → PositionManager
    function _approve(address token) internal {
        require(IERC20Like(token).approve(PERMIT2, type(uint256).max), "approve failed");
        IAllowanceTransfer(PERMIT2).approve(token, POSITION_MANAGER, type(uint160).max, type(uint48).max);
    }

    /// @dev price = USDC units / ETH wei = P * 1e6 / 1e18 = usd8 / 1e20, sqrtPriceX96 = sqrt(price * 2^192)
    function _sqrtPriceFromUsd8(uint256 usd8) internal pure returns (uint160) {
        return uint160(_sqrt(FullMath.mulDiv(usd8, 1 << 192, 1e20)));
    }

    function _floorToSpacing(int24 tick) internal pure returns (int24) {
        int24 q = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) q -= 1;
        return q * TICK_SPACING;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

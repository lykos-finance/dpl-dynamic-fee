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

interface IERC20Meta {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice Creates a native ETH / TOKEN pool (for example ETH/VJDX) with VolatilityGuardHookV8 on
///         Ethereum mainnet and mints the first LP position to the deployer, in one transaction.
///
/// There is no oracle for an arbitrary token, so the starting price comes from TOKEN_PRICE_ETH:
/// the price of one whole token in ETH, with 18 decimals (`cast to-wei 0.0001` for 0.0001 ETH).
///
/// Native ETH is always currency0, so a higher token price in ETH is a lower tick.
///
/// Env:
///   PRIVATE_KEY, HOOK_ADDRESS_V8
///   TOKEN_ADDRESS        token contract
///   TOKEN_PRICE_ETH      price of 1 token in ETH, 18 decimals
///   TOKEN_LP_ETH         ETH for the position, wei. The token amount follows from the price
///   TOKEN_FULL_RANGE     true (default): the whole price range
///   TOKEN_RANGE_BELOW_PCT / TOKEN_RANGE_ABOVE_PCT   range around the price when not full range, % (default 50)
contract InitPoolV8Token is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ── Mainnet addresses ──
    address constant POOL_MANAGER     = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    int24 constant TICK_SPACING = 60;

    struct Position {
        int24   tickLower;
        int24   tickUpper;
        uint160 startSqrtPrice;
        uint128 liquidity;
        uint256 ethMax;
        uint256 tokenMax;
    }

    function run() public {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address hook     = vm.envAddress("HOOK_ADDRESS_V8");
        address token    = vm.envAddress("TOKEN_ADDRESS");

        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");
        require(hook.code.length != 0, "HOOK_ADDRESS_V8 has no code");
        require(address(VolatilityGuardHookV8(hook).poolManager()) == POOL_MANAGER, "Hook uses another PoolManager");
        require(token.code.length != 0, "TOKEN_ADDRESS has no code");

        uint8 decimals = IERC20Meta(token).decimals();
        console.log("=== InitPoolV8Token ===");
        console.log("Deployer:", deployer);
        console.log("Hook:    ", hook);
        console.log("Token:   ", IERC20Meta(token).symbol(), token);
        console.log("Decimals:", decimals);

        PoolKey memory key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook)
        );
        (uint160 existingPrice,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        require(existingPrice == 0, "Pool already initialized");

        Position memory position = _planPosition(decimals);
        console.log("ETH max (wei):  ", position.ethMax);
        console.log("Token max:      ", position.tokenMax);
        require(deployer.balance >= position.ethMax, "Not enough ETH");
        require(IERC20Meta(token).balanceOf(deployer) >= position.tokenMax, "Not enough token");

        bytes[] memory calls = _initAndMintCalls(key, position, deployer);
        uint256 tokenId = IPositionManager(POSITION_MANAGER).nextTokenId();

        vm.startBroadcast(pk);
        _approve(token);
        // Unused ETH is swept back to the deployer in the same call
        IMulticall_v4(POSITION_MANAGER).multicall{value: position.ethMax}(calls);
        vm.stopBroadcast();

        console.log("\n=== DONE ===");
        console.log("Position tokenId:", tokenId);
        console.log("\nAdd to .env:");
        console.log(string.concat("POOL_ID_TOKEN=", vm.toString(PoolId.unwrap(key.toId()))));
        console.log(string.concat("TOKEN_ID=", vm.toString(tokenId)));
    }

    function _planPosition(uint8 decimals) internal view returns (Position memory p) {
        uint256 priceE18  = vm.envUint("TOKEN_PRICE_ETH");
        uint256 ethAmount = vm.envUint("TOKEN_LP_ETH");
        bool fullRange    = vm.envOr("TOKEN_FULL_RANGE", true);
        require(priceE18 > 0, "TOKEN_PRICE_ETH not set");
        require(ethAmount > 0, "TOKEN_LP_ETH not set");
        console.log("Token price (ETH, 18 dec):", priceE18);

        p.startSqrtPrice = _sqrtPrice(priceE18, decimals);
        if (fullRange) {
            p.tickLower = TickMath.minUsableTick(TICK_SPACING);
            p.tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        } else {
            uint256 below = vm.envOr("TOKEN_RANGE_BELOW_PCT", uint256(50));
            uint256 above = vm.envOr("TOKEN_RANGE_ABOVE_PCT", uint256(50));
            require(below > 0 && below < 100 && above > 0, "Bad range");
            // A higher token price is a lower tick
            p.tickLower = _floorToSpacing(TickMath.getTickAtSqrtPrice(_sqrtPrice(priceE18 * (100 + above) / 100, decimals)));
            p.tickUpper = _floorToSpacing(TickMath.getTickAtSqrtPrice(_sqrtPrice(priceE18 * (100 - below) / 100, decimals)))
                + TICK_SPACING;
        }
        console.log("Tick range:");
        console.logInt(p.tickLower);
        console.logInt(p.tickUpper);

        uint256 tokenAmount = FullMath.mulDiv(ethAmount, 10 ** decimals, priceE18);
        p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            p.startSqrtPrice,
            TickMath.getSqrtPriceAtTick(p.tickLower),
            TickMath.getSqrtPriceAtTick(p.tickUpper),
            ethAmount,
            tokenAmount
        );
        require(p.liquidity > 0, "Zero liquidity");

        // The position takes at most the target amounts, 1% covers rounding
        p.ethMax   = (ethAmount * 101) / 100 + 1;
        p.tokenMax = (tokenAmount * 101) / 100 + 1;
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
            key, p.tickLower, p.tickUpper, uint256(p.liquidity), uint128(p.ethMax), uint128(p.tokenMax), recipient, bytes("")
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
        require(IERC20Meta(token).approve(PERMIT2, type(uint256).max), "approve failed");
        IAllowanceTransfer(PERMIT2).approve(token, POSITION_MANAGER, type(uint160).max, type(uint48).max);
    }

    /// @dev price = token units per ETH wei = 10^decimals / priceE18, sqrtPriceX96 = sqrt(price * 2^192)
    function _sqrtPrice(uint256 priceE18, uint8 decimals) internal pure returns (uint160 sqrtPrice) {
        sqrtPrice = uint160(_sqrt(FullMath.mulDiv(10 ** decimals, 1 << 192, priceE18)));
        require(sqrtPrice > TickMath.MIN_SQRT_PRICE && sqrtPrice < TickMath.MAX_SQRT_PRICE, "Price out of range");
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

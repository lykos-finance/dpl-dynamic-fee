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

interface IERC20Like {
    function symbol() external view returns (string memory);
}

/// @notice Removes all liquidity from a Uniswap v4 LP position and burns the NFT
contract RemoveLiquidity is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ── Mainnet addresses ──
    address constant POOL_MANAGER      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER  = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant WETH              = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT              = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() public {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        uint256 tokenId  = vm.envUint("TOKEN_ID");
        address deployer = vm.addr(pk);

        console.log("=== RemoveLiquidity ===");
        console.log("Deployer:", deployer);
        console.log("Hook:", hookAddr);
        console.log("TokenId:", tokenId);

        IPositionManager pm = IPositionManager(POSITION_MANAGER);

        // ── 1. Sort tokens ──
        IERC20Like tokenA = IERC20Like(WETH);
        IERC20Like tokenB = IERC20Like(USDT);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        console.log("[1] Token0:", tokenA.symbol(), address(tokenA));
        console.log("[1] Token1:", tokenB.symbol(), address(tokenB));

        // ── 2. PoolKey ──
        PoolKey memory key = PoolKey(
            Currency.wrap(address(tokenA)),
            Currency.wrap(address(tokenB)),
            0x800000, 60, IHooks(hookAddr)
        );
        PoolId poolId = key.toId();
        console.log("[2] PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));

        // ── 3. Get position liquidity ──
        uint128 liquidity = pm.getPositionLiquidity(tokenId);
        console.log("[3] Position liquidity:", liquidity);
        require(liquidity > 0, "Position has no liquidity");

        // ════════════════════════════════════════════════════════════════════
        // START BROADCAST
        // ════════════════════════════════════════════════════════════════════
        vm.startBroadcast(pk);

        // ── 4. Decrease liquidity to 0, then burn the NFT ──
        // DECREASE_LIQUIDITY: removes liquidity, credits tokens as deltas
        // BURN_POSITION: burns the NFT (requires liquidity == 0)
        // TAKE_PAIR: sends both token deltas to the recipient
        console.log("[4] Removing liquidity and burning position...");

        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.BURN_POSITION),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](3);

        // DECREASE_LIQUIDITY params: tokenId, liquidity, amount0Min, amount1Min, hookData
        params[0] = abi.encode(
            tokenId,
            liquidity,
            uint128(0), // amount0Min — set to 0 for simplicity, use slippage protection in prod
            uint128(0), // amount1Min
            bytes("")
        );

        // BURN_POSITION params: tokenId, amount0Min, amount1Min, hookData
        params[1] = abi.encode(
            tokenId,
            uint128(0),
            uint128(0),
            bytes("")
        );

        // TAKE_PAIR params: currency0, currency1, recipient
        params[2] = abi.encode(
            key.currency0,
            key.currency1,
            deployer
        );

        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);

        console.log("[4] Liquidity removed and position burned!");

        vm.stopBroadcast();
        console.log("\n=== DONE ===");
    }
}

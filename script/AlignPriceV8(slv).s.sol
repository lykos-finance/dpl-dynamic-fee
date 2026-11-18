// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolPriceAligner} from "../src/PoolPriceAligner.sol";

interface IFeedA {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Moves an EMPTY native ETH / TOKEN pool with VolatilityGuardHookV8 to the market price.
///         Refuses a pool with active liquidity: there the swap would trade against real LPs.
///
/// Env:
///   PRIVATE_KEY, HOOK_ADDRESS_V8
///   ALIGN_TOKEN       pool token (default USDC)
///   ALIGN_PRICE_ETH   price of 1 token in ETH, 18 decimals. Not needed for USDC: Chainlink ETH/USD is used
///   ALIGNER           an already deployed PoolPriceAligner (optional, otherwise one is deployed)
contract AlignPriceV8 is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant USDC              = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    int24 constant TICK_SPACING = 60;
    uint256 constant MAX_STALENESS = 3600;
    // Only the hook's 0.001% treasury share of this is ever spent in an empty pool
    uint256 constant MAX_IN = 1e12;

    function run() external {
        uint256 pk   = vm.envUint("PRIVATE_KEY");
        address hook = vm.envAddress("HOOK_ADDRESS_V8");
        address token = vm.envOr("ALIGN_TOKEN", USDC);
        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");

        PoolKey memory key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook)
        );
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        (uint160 current,,,) = pm.getSlot0(key.toId());
        require(current != 0, "Pool not initialized");
        require(pm.getLiquidity(key.toId()) == 0, "Pool has active liquidity - not an empty pool");

        uint160 target = _target(token);
        console.log("=== AlignPriceV8 ===");
        console.log("Pool price now (token units per ETH, x1e6 for USDC):", _price(current));
        console.log("Target                                                :", _price(target));

        vm.startBroadcast(pk);
        address aligner = vm.envOr("ALIGNER", address(0));
        if (aligner == address(0)) aligner = address(new PoolPriceAligner(pm));
        PoolPriceAligner(payable(aligner)).align{value: MAX_IN}(key, target, MAX_IN);
        vm.stopBroadcast();

        (uint160 after_,,,) = pm.getSlot0(key.toId());
        console.log("Pool price after:", _price(after_));
        console.log(string.concat("ALIGNER=", vm.toString(aligner)));
    }

    function _target(address token) internal view returns (uint160) {
        if (token == USDC) {
            (, int256 answer,, uint256 updatedAt,) = IFeedA(CHAINLINK_ETH_USD).latestRoundData();
            require(answer > 0 && block.timestamp - updatedAt <= MAX_STALENESS, "Chainlink: bad price");
            console.log("ETH price (USD * 1e8):", uint256(answer));
            return uint160(_sqrt(FullMath.mulDiv(uint256(answer), 1 << 192, 1e20)));
        }
        uint256 priceE18 = vm.envUint("ALIGN_PRICE_ETH");
        uint8 decimals = IDecimals(token).decimals();
        return uint160(_sqrt(FullMath.mulDiv(10 ** decimals, 1 << 192, priceE18)));
    }

    /// @dev Raw price, token1 units per 1e18 wei of ETH (for USDC: USDC with 6 decimals per ETH)
    function _price(uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtP) * uint256(sqrtP), 1e18, 1 << 192);
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

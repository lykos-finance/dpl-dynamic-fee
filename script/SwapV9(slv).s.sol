// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {VolatilityGuardHookV9} from "../src/dynamic-fee(slv-V9).sol";
import {V9Common, IERC20V9} from "./V9Common(slv).sol";

interface IUniversalRouterV9 {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev The deployed V4 Quoter on mainnet
interface IV4QuoterV9 {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice Exact-input swaps in a VolatilityGuardHookV9 pool, native ETH or WETH (either side), through
///         the Universal Router. BuyV9 pays the ETH side for the token, SellV9 sells the token for it.
///
/// Env:
///   PRIVATE_KEY, HOOK_ADDRESS_V9
///   SWAP_TOKEN          the pool's token
///   USE_WETH            false (default): native ETH pool. true: WETH pool; WETH to pay is wrapped if missing
///   SWAP_AMOUNT         amount in: wei for BuyV9, token units for SellV9
///   SWAP_SLIPPAGE_BPS   allowed slippage against the quote, bps (default 100)
abstract contract SwapV9Base is V9Common {
    using PoolIdLibrary for PoolKey;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant V4_QUOTER        = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;

    uint8 constant V4_SWAP              = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE_ALL           = 0x0c;
    uint8 constant TAKE_ALL             = 0x0f;

    /// @dev The deployed Universal Router's struct, without the newer minHopPriceX36 field
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    function _swap(address token, bool useWeth, bool buy) internal {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);
        address hook = vm.envAddress("HOOK_ADDRESS_V9");
        uint256 amountIn = vm.envUint("SWAP_AMOUNT");
        uint256 slippage = vm.envOr("SWAP_SLIPPAGE_BPS", uint256(100));
        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");
        require(amountIn > 0 && amountIn <= type(uint128).max, "Bad SWAP_AMOUNT");
        require(slippage < 10_000, "Bad SWAP_SLIPPAGE_BPS");

        Pair memory p = _pair(hook, token, useWeth);
        // Buying the token: the ETH side goes in
        bool zeroForOne = buy == p.ethIs0;
        bool native = p.ethSide == address(0);

        console.log(buy ? "=== BuyV9 ===" : "=== SellV9 ===", IERC20V9(token).symbol(), native ? "/ native ETH" : "/ WETH");
        console.log("Amount in:", amountIn);
        if (buy) {
            if (native) require(trader.balance >= amountIn, "Not enough ETH");
            else require(IERC20V9(WETH).balanceOf(trader) + trader.balance >= amountIn, "Not enough ETH + WETH");
        } else {
            require(IERC20V9(token).balanceOf(trader) >= amountIn, "Not enough token");
        }

        (uint256 quoted,) = IV4QuoterV9(V4_QUOTER).quoteExactInputSingle(
            IV4QuoterV9.QuoteExactSingleParams(p.key, zeroForOne, uint128(amountIn), bytes(""))
        );
        uint256 minOut = quoted * (10_000 - slippage) / 10_000;
        require(minOut > 0, "Quote is zero - no liquidity?");
        console.log("Quoted out:", quoted);
        console.log("Min out:   ", minOut);
        console.log("Fee now, pips:", VolatilityGuardHookV9(hook).currentFee(p.key.toId()));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _v4SwapInput(p.key, zeroForOne, uint128(amountIn), uint128(minOut));

        vm.startBroadcast(pk);
        address payToken = buy ? p.ethSide : token;
        if (payToken != address(0)) {
            if (payToken == WETH) _wrapShortfall(trader, amountIn);
            _approveViaPermit2(payToken, trader, UNIVERSAL_ROUTER, amountIn, uint48(block.timestamp + 300));
        }
        IUniversalRouterV9(UNIVERSAL_ROUTER).execute{value: payToken == address(0) ? amountIn : 0}(
            abi.encodePacked(V4_SWAP), inputs, block.timestamp + 300
        );
        vm.stopBroadcast();
    }

    function _v4SwapInput(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minOut)
        internal
        pure
        returns (bytes memory)
    {
        (Currency tokenIn, Currency tokenOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amountIn, minOut, bytes("")));
        params[1] = abi.encode(tokenIn, uint256(amountIn));
        params[2] = abi.encode(tokenOut, uint256(minOut));
        return abi.encode(actions, params);
    }
}

/// @notice Buy the token with the ETH side (native ETH or WETH). SWAP_AMOUNT in wei
contract BuyV9 is SwapV9Base {
    function run() external {
        _swap(vm.envAddress("SWAP_TOKEN"), vm.envOr("USE_WETH", false), true);
    }
}

/// @notice Sell the token for the ETH side (native ETH or WETH). SWAP_AMOUNT in token units
contract SellV9 is SwapV9Base {
    function run() external {
        _swap(vm.envAddress("SWAP_TOKEN"), vm.envOr("USE_WETH", false), false);
    }
}

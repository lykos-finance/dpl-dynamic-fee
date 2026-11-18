// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {VolatilityGuardHookV8} from "../src/dynamic-fee(slv-V8).sol";

interface IERC20Swap {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev The deployed V4 Quoter on mainnet
interface IV4QuoterMainnet {
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

/// @notice Exact-input swaps in a native ETH / TOKEN pool with VolatilityGuardHookV8 on Ethereum mainnet,
///         through the Uniswap Universal Router. BuyV8 pays ETH for the token, SellV8 sells the token for ETH.
///
/// The minimum output is the Quoter's answer minus SWAP_SLIPPAGE_BPS. The quote runs the real hook,
/// so it already includes the dynamic fee.
///
/// Env:
///   PRIVATE_KEY, HOOK_ADDRESS_V8
///   SWAP_TOKEN          the pool's token (default USDC)
///   SWAP_AMOUNT         amount in: wei for BuyV8, token units for SellV8 (`cast to-unit` / `cast to-wei`)
///   SWAP_SLIPPAGE_BPS   allowed slippage against the quote, in bps (default 100 = 1%)
abstract contract SwapV8Base is Script {
    using PoolIdLibrary for PoolKey;

    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant V4_QUOTER        = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POOL_MANAGER     = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant USDC             = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    int24 constant TICK_SPACING = 60;

    // Universal Router command and V4Router actions
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

    function _swap(bool buy) internal {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address trader   = vm.addr(pk);
        address hook     = vm.envAddress("HOOK_ADDRESS_V8");
        address token    = vm.envOr("SWAP_TOKEN", USDC);
        uint256 amountIn = vm.envUint("SWAP_AMOUNT");
        uint256 slippage = vm.envOr("SWAP_SLIPPAGE_BPS", uint256(100));

        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");
        require(hook.code.length != 0, "HOOK_ADDRESS_V8 has no code");
        require(address(VolatilityGuardHookV8(hook).poolManager()) == POOL_MANAGER, "Hook uses another PoolManager");
        require(amountIn > 0 && amountIn <= type(uint128).max, "Bad SWAP_AMOUNT");
        require(slippage < 10_000, "Bad SWAP_SLIPPAGE_BPS");

        PoolKey memory key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook)
        );
        // Native ETH is currency0, so buying the token is zeroForOne
        bool zeroForOne = buy;

        string memory symbol = IERC20Swap(token).symbol();
        console.log(buy ? "=== BuyV8: ETH ->" : "=== SellV8: ->  ETH", symbol);
        console.log("Trader:   ", trader);
        console.log("Amount in:", amountIn, buy ? "wei" : "token units");
        if (buy) {
            require(trader.balance >= amountIn, "Not enough ETH");
        } else {
            require(IERC20Swap(token).balanceOf(trader) >= amountIn, "Not enough token");
        }

        (uint256 quoted,) = IV4QuoterMainnet(V4_QUOTER).quoteExactInputSingle(
            IV4QuoterMainnet.QuoteExactSingleParams(key, zeroForOne, uint128(amountIn), bytes(""))
        );
        uint256 minOut = quoted * (10_000 - slippage) / 10_000;
        require(minOut > 0, "Quote is zero - no liquidity?");
        console.log("Quoted out:", quoted, buy ? "token units" : "wei");
        console.log("Min out:   ", minOut);
        console.log("Fee now (pips, before own move):", VolatilityGuardHookV8(hook).currentFee(key.toId()));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _v4SwapInput(key, zeroForOne, uint128(amountIn), uint128(minOut));

        uint256 outBefore = buy ? IERC20Swap(token).balanceOf(trader) : trader.balance;

        vm.startBroadcast(pk);
        if (!buy) _approve(token, amountIn);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: buy ? amountIn : 0}(
            abi.encodePacked(V4_SWAP), inputs, block.timestamp + 300
        );
        vm.stopBroadcast();

        uint256 outAfter = buy ? IERC20Swap(token).balanceOf(trader) : trader.balance;
        // For a sell the simulated balance also drops by gas, so the printed ETH figure is approximate
        if (outAfter > outBefore) console.log("Received:  ", outAfter - outBefore);
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

    /// @dev token → Permit2 → Universal Router, only as much as this swap needs
    function _approve(address token, uint256 amount) internal {
        if (IERC20Swap(token).allowance(vm.addr(vm.envUint("PRIVATE_KEY")), PERMIT2) < amount) {
            require(IERC20Swap(token).approve(PERMIT2, type(uint256).max), "approve failed");
        }
        IAllowanceTransfer(PERMIT2).approve(token, UNIVERSAL_ROUTER, uint160(amount), uint48(block.timestamp + 300));
    }
}

/// @notice Buy the token with native ETH. SWAP_AMOUNT is ETH in wei
contract BuyV8 is SwapV8Base {
    function run() external {
        _swap(true);
    }
}

/// @notice Sell the token for native ETH. SWAP_AMOUNT is in the token's own units
contract SellV8 is SwapV8Base {
    function run() external {
        _swap(false);
    }
}

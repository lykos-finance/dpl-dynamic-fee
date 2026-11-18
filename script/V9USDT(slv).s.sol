// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {InitPoolV9} from "./InitPoolV9(slv).s.sol";
import {SwapV9Base} from "./SwapV9(slv).s.sol";

/// @notice USDT pools with VolatilityGuardHookV9: creation and swaps with the token fixed to USDT.
///
/// USDT's approve returns nothing and reverts when changing a non-zero allowance to another non-zero
/// value. These scripts go through V9Common._safeApprove, which accepts an empty return and resets the
/// allowance to 0 first, so they work where a plain `require(token.approve(...))` would revert.
///
/// Price: the hook's Chainlink USDT/ETH oracle. Base fee: 0.05%.
/// With USE_WETH=true WETH is currency0 (its address is below USDT's), and only the hook's initializer
/// can create the pool.
///
/// Env: as InitPoolV9 / SwapV9, without TOKEN_ADDRESS or SWAP_TOKEN:
///   InitPoolUSDT: PRIVATE_KEY, HOOK_ADDRESS_V9, LP_ETH, [USE_WETH], [LP_RANGE_BELOW_PCT/ABOVE_PCT | LP_FULL_RANGE]
///   BuyUSDT / SellUSDT: PRIVATE_KEY, HOOK_ADDRESS_V9, SWAP_AMOUNT (wei / USDT units, 6 decimals),
///                       [USE_WETH], [SWAP_SLIPPAGE_BPS]
contract InitPoolUSDT is InitPoolV9 {
    function run() public override {
        _run(USDT, vm.envOr("USE_WETH", false));
    }
}

contract BuyUSDT is SwapV9Base {
    function run() external {
        _swap(USDT, vm.envOr("USE_WETH", false), true);
    }
}

contract SellUSDT is SwapV9Base {
    function run() external {
        _swap(USDT, vm.envOr("USE_WETH", false), false);
    }
}

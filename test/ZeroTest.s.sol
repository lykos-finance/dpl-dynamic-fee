// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

interface IRobustRouter {
    function removeLiquidity(PoolKey memory key, int24 tl, int24 tu, int256 amount) external;
}

contract ZeroTest is Script {
    using CurrencyLibrary for Currency;

    address constant HOOK_ADDR    = 0x31e06569CA3aCbe38BFEefF0e2458780bA41c080; 
    address constant ROUTER_ADDR  = 0x49F7C55B3b6945109C4A5bAa7A5631CD7529Cb53;
    address constant WETH_ADDR    = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT_ADDR    = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        console.log("--- ZERO WITHDRAWAL TEST ---");

        PoolKey memory key = PoolKey(Currency.wrap(WETH_ADDR), Currency.wrap(USDT_ADDR), 8388608, 60, IHooks(HOOK_ADDR));
        
        // Попытка снять 0. Это проверит работоспособность Хука.
        console.log("Removing 0 liquidity...");
        try IRobustRouter(ROUTER_ADDR).removeLiquidity(key, -196320, -193920, 0) {
            console.log(">>> SUCCESS: Hook is alive!");
        } catch Error(string memory reason) {
            console.log(">>> FAIL Reason:", reason);
        } catch {
            console.log(">>> FAIL: Hook Crashed (Unknown Error)");
        }

        vm.stopBroadcast();
    }
}

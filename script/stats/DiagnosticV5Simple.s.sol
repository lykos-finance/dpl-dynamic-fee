// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

interface IVolatilityHook {
    function getState(PoolId id) external view returns (int24, uint256, bool);
}

contract DiagnosticV5Simple is Script {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() external view {
        address hook = vm.envAddress("HOOK_ADDRESS_V5");
        console.log("Hook:", hook);
        
        uint160 bits = uint160(hook) & 0x3FFF;
        console.log("Flags:", bits, bits == 0x0082 ? "OK" : "FAIL");
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDT),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        
        PoolId id = PoolIdLibrary.toId(key);
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        (uint160 sqrtP, int24 tick,,) = StateLibrary.getSlot0(pm, id);
        
        console.log("SqrtPrice:", uint256(sqrtP));
        console.log("Tick:", int256(tick));
        
        if (sqrtP > 0) {
            console.log("Pool: INITIALIZED");
        } else {
            console.log("Pool: NOT INITIALIZED");
        }
    }
}

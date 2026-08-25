import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract CheckPool is Script {
    using StateLibrary for IPoolManager;

    function run() public view {
        IPoolManager manager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        PoolId poolId = PoolId.wrap(bytes32(vm.envBytes32("POOL_ID")));

        (uint160 sqrtPriceX96, int24 tick, , ) = manager.getSlot0(poolId);
        uint128 liquidity = manager.getLiquidity(poolId);

        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.logInt(tick);
        console.log("liquidity:", liquidity);
    }
}
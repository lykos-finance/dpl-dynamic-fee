// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "../test/libraries/HookMiner.sol";
import {VolatilityGuardHookV8} from "../src/dynamic-fee(slv-V8).sol";

contract HookFactoryV8 {
    event HookDeployed(address indexed hook, bytes32 salt);

    function deploy(bytes memory bytecode, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) { revert(0, 0) }
        }
        require(addr != address(0), "HookFactory: deployment failed");
        emit HookDeployed(addr, salt);
    }
}

/// @notice Deploy VolatilityGuardHookV8 on Ethereum mainnet. The hook has no owner and no constructor roles.
contract DeployV8 is Script {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");

        console.log("=== DeployV8 ===");
        console.log("Deployer:    ", deployer);
        console.log("PoolManager: ", POOL_MANAGER);
        console.log("Chain ID:    ", block.chainid);

        // ── 1. Deploy factory ──
        vm.startBroadcast(pk);
        HookFactoryV8 factory = new HookFactoryV8();
        vm.stopBroadcast();
        console.log("Factory:     ", address(factory));

        // ── 2. Mine salt ──
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(POOL_MANAGER);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(factory), flags, type(VolatilityGuardHookV8).creationCode, args);
        console.log("Predicted hook:", predicted);
        console.log("Salt:          ", vm.toString(salt));
        require(uint160(predicted) & uint160(0x3FFF) == flags, "Wrong flags");

        // ── 3. Deploy hook ──
        vm.startBroadcast(pk);
        address hook = factory.deploy(abi.encodePacked(type(VolatilityGuardHookV8).creationCode, args), salt);
        vm.stopBroadcast();
        require(hook == predicted, "Hook addr mismatch");
        require(address(VolatilityGuardHookV8(hook).poolManager()) == POOL_MANAGER, "PoolManager mismatch");
        console.log("Hook:          ", hook);

        console.log("\nAdd to .env:");
        console.log(string.concat("HOOK_ADDRESS_V8=", vm.toString(hook)));
    }
}

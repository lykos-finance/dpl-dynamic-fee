// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "../test/libraries/HookMiner.sol";
import {VolatilityGuardHookV7} from "../src/VolatilityGuardHookV7.sol";

contract HookFactoryV7 {
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

/// @notice Deploy VolatilityGuardHookV7 on Ethereum mainnet.
contract DeployV7 is Script {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // ── Guardian берётся из .env ──
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");

        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");
        require(guardian != address(0),  "GUARDIAN_ADDRESS not set");
        require(guardian != deployer,    "guardian must differ from deployer/owner");

        console.log("=== DeployV7 ===");
        console.log("Deployer:    ", deployer);
        console.log("Guardian:    ", guardian);
        console.log("PoolManager: ", POOL_MANAGER);
        console.log("Chain ID:    ", block.chainid);

        // ── 1. Deploy factory ──
        vm.startBroadcast(pk);
        HookFactoryV7 factory = new HookFactoryV7();
        vm.stopBroadcast();
        console.log("Factory:     ", address(factory));

        // ── 2. Mine salt (constructor: POOL_MANAGER, owner=deployer, guardian) ──
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG);
        (address predicted, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(VolatilityGuardHookV7).creationCode,
            abi.encode(POOL_MANAGER, deployer, guardian)  // <── все три аргумента
        );
        console.log("Predicted hook:", predicted);
        console.log("Salt:          ", vm.toString(salt));
        require(uint160(predicted) & uint160(0x3FFF) == flags, "Wrong flags");

        // ── 3. Deploy hook ──
        vm.startBroadcast(pk);
        bytes memory bytecode = abi.encodePacked(
            type(VolatilityGuardHookV7).creationCode,
            abi.encode(POOL_MANAGER, deployer, guardian)  // <── все три аргумента
        );
        address hook = factory.deploy(bytecode, salt);
        vm.stopBroadcast();
        require(hook == predicted, "Hook addr mismatch");
        console.log("Hook:          ", hook);

        console.log("\nAdd to .env:");
        console.log(string.concat("HOOK_ADDRESS_V7=", vm.toString(hook)));
    }
}
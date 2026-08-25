// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "../test/libraries/HookMiner.sol";
import {SwapLoggerHook} from "../src/SwapLoggerHook.sol";

contract HookFactorySwapLogger {
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

/// @notice Deploy SwapLoggerHook on Ethereum mainnet.
contract DeploySwapLoggerHook is Script {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // ── Owners мультисига берутся из .env ──
        address owner1 = vm.envAddress("HOOK_OWNER1");
        address owner2 = vm.envAddress("HOOK_OWNER2");

        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");
        require(owner1 != address(0), "HOOK_OWNER1 not set");
        require(owner2 != address(0), "HOOK_OWNER2 not set");
        require(owner1 != owner2,     "owners must differ");

        console.log("=== DeploySwapLoggerHook ===");
        console.log("Deployer:    ", deployer);
        console.log("Owner1:      ", owner1);
        console.log("Owner2:      ", owner2);
        console.log("PoolManager: ", POOL_MANAGER);
        console.log("Chain ID:    ", block.chainid);

        // ── 1. Deploy factory ──
        vm.startBroadcast(pk);
        HookFactorySwapLogger factory = new HookFactorySwapLogger();
        vm.stopBroadcast();
        console.log("Factory:     ", address(factory));

        // ── 2. Mine salt (constructor: POOL_MANAGER, owner1, owner2) ──
        // ВАЖНО: хук теперь использует beforeSwap (override комиссии "для вида")
        // И afterSwap (логирование) — оба флага должны быть в адресе,
        // иначе Hooks.validateHookPermissions() в конструкторе хука упадёт.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address predicted, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(SwapLoggerHook).creationCode,
            abi.encode(POOL_MANAGER, owner1, owner2)
        );
        console.log("Predicted hook:", predicted);
        console.log("Salt:          ", vm.toString(salt));
        require(uint160(predicted) & uint160(0x3FFF) == flags, "Wrong flags");

        // ── 3. Deploy hook ──
        vm.startBroadcast(pk);
        bytes memory bytecode = abi.encodePacked(
            type(SwapLoggerHook).creationCode,
            abi.encode(POOL_MANAGER, owner1, owner2)
        );
        address hook = factory.deploy(bytecode, salt);
        vm.stopBroadcast();
        require(hook == predicted, "Hook addr mismatch");
        console.log("Hook:          ", hook);

        console.log("\nAdd to .env:");
        console.log(string.concat("HOOK_ADDRESS_SWAPLOGGER=", vm.toString(hook)));
    }
}
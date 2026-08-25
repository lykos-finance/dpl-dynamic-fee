// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "../../test/libraries/HookMiner.sol";

import {VolatilityGuardHookV4} from "../../src/VolatilityGuardHookV4.sol";

contract HookFactoryArb {
    event HookDeployed(address indexed hook, bytes32 salt);

    function deploy(bytes memory bytecode, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        require(addr != address(0), "HookFactory: deployment failed");
        emit HookDeployed(addr, salt);
    }
}

/// @notice Deploy VolatilityGuardHookV4 on Arbitrum One (chain 42161).
/// @dev ENV: PRIVATE_KEY
contract DeployArb is Script {
    // Uniswap v4 on Arbitrum One
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        require(block.chainid == 42161, "Wrong chain - need Arbitrum One (42161)");

        console.log("=== DeployArb ===");
        console.log("Deployer:    ", deployer);
        console.log("PoolManager: ", POOL_MANAGER);
        console.log("Chain ID:    ", block.chainid);

        vm.startBroadcast(pk);
        HookFactoryArb factory = new HookFactoryArb();
        vm.stopBroadcast();
        console.log("Factory:     ", address(factory));

        // Mine salt
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        (address predicted, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(VolatilityGuardHookV4).creationCode,
            abi.encode(POOL_MANAGER)
        );
        console.log("Predicted hook:", predicted);
        console.log("Salt:        ", vm.toString(salt));
        require(uint160(predicted) & uint160(0x3FFF) == flags, "Wrong flags");

        // Deploy hook
        vm.startBroadcast(pk);
        bytes memory bytecode = abi.encodePacked(
            type(VolatilityGuardHookV4).creationCode,
            abi.encode(POOL_MANAGER)
        );
        address hook = factory.deploy(bytecode, salt);
        vm.stopBroadcast();
        require(hook == predicted, "Hook addr mismatch");
        console.log("Hook:        ", hook);

        console.log("\nAdd to .env:");
        console.log(string.concat("HOOK_ADDRESS_ARB=", vm.toString(hook)));
    }
}

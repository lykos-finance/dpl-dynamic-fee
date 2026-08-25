// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "../test/libraries/HookMiner.sol";

import {VolatilityGuardHookV2} from "../src/VolatilityGuardHookV2.sol";
import {RobustRouterV6} from "../src/RobustRouterV6.sol";

contract HookFactory {
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

contract DeployScript is Script {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOYMENT CONFIGURATION ===");
        console.log("Deployer:", deployer);
        console.log("PoolManager:", POOL_MANAGER);
        console.log("Chain ID:", block.chainid);

        // ─── ШАГ 1: деплоим фабрику ───────────────────────────────────────────
        // ВАЖНО: фабрика должна быть задеплоена ДО поиска соли,
        // потому что HookMiner использует address(factory) как deployer для CREATE2.
        // Если деплоить фабрику после — предсказанный адрес хука будет неверным.
        vm.startBroadcast(deployerPrivateKey);
        HookFactory factory = new HookFactory();
        vm.stopBroadcast();

        console.log("\n=== STEP 1: FACTORY DEPLOYED ===");
        console.log("Factory:", address(factory));

        // ─── ШАГ 2: майнинг соли (вне broadcast — это чистые вычисления) ───────
        // HookMiner.find принимает (deployer=factory, flags, creationCode, constructorArgs)
        // и перебирает salt до тех пор, пока address(CREATE2(factory, salt, bytecode))
        // не будет иметь нужные биты флагов в младших 14 битах.
        console.log("\n=== STEP 2: MINING SALT ===");

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        (address predictedHookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(VolatilityGuardHookV2).creationCode,
            abi.encode(POOL_MANAGER)
        );

        console.log("Predicted hook address:", predictedHookAddress);
        console.log("Salt:", vm.toString(salt));

        // Проверяем, что флаги совпадают
        require(
            uint160(predictedHookAddress) & uint160(0x3FFF) == flags,
            "Salt mining produced wrong flags"
        );

        // ─── ШАГ 3: деплой хука и роутера ────────────────────────────────────
        // КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ:
        // RobustRouterV6 конструктор делает owner = msg.sender.
        // При vm.startBroadcast(deployerPrivateKey) msg.sender == deployer (EOA).
        // Роутер задеплоен через `new` — msg.sender корректен.
        // НЕ деплоить роутер через factory.deploy() — иначе msg.sender = factory,
        // и owner будет address(factory), а не EOA!
        vm.startBroadcast(deployerPrivateKey);

        bytes memory hookBytecode = abi.encodePacked(
            type(VolatilityGuardHookV2).creationCode,
            abi.encode(POOL_MANAGER)
        );

        address hookAddress = factory.deploy(hookBytecode, salt);

        require(hookAddress == predictedHookAddress, "Hook address mismatch!");
        console.log("\n=== STEP 3: HOOK DEPLOYED ===");
        console.log("Hook:", hookAddress);

        // Верификация флагов хука
        require(
            uint160(hookAddress) & uint160(0x3FFF) == flags,
            "Hook address has wrong permission bits"
        );
        console.log("Hook permission bits: OK");

        // Роутер деплоится через `new` — msg.sender == deployer == owner (CORRECT)
        RobustRouterV6 router = new RobustRouterV6(IPoolManager(POOL_MANAGER));

        // Явная проверка: owner роутера должен быть deployer, а не что-то другое
        require(router.owner() == deployer, "CRITICAL: Router owner != deployer!");
        console.log("\n=== STEP 4: ROUTER DEPLOYED ===");
        console.log("Router:", address(router));
        console.log("Router owner:", router.owner());
        console.log("Owner == deployer:", router.owner() == deployer);

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Factory :", address(factory));
        console.log("Hook    :", hookAddress);
        console.log("Router  :", address(router));

        console.log("\nAdd to .env:");
        console.log(string.concat("HOOK_ADDRESS=",    vm.toString(hookAddress)));
        console.log(string.concat("ROUTER_ADDRESS=",  vm.toString(address(router))));
        console.log(string.concat("FACTORY_ADDRESS=", vm.toString(address(factory))));
    }
}
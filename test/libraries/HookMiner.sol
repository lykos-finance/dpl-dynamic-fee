// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library HookMiner {
    // Функция поиска соли для майнинга адреса хука
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address, bytes32) {
        // 1. Собираем полный байт-код: код контракта + аргументы
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        
        // 2. Считаем его хеш (именно он влияет на адрес)
        bytes32 bytecodeHash = keccak256(bytecode);

        address hookAddress;
        bytes32 salt;

        // 3. Перебираем соль (до 10 млн итераций)
        for (uint256 i = 0; i < 10000000; i++) {
            salt = bytes32(i);
            
            // Вычисляем CREATE2 адрес: hash(0xff + deployer + salt + bytecodeHash)
            hookAddress = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff),
                deployer,
                salt,
                bytecodeHash
            )))));

            // 4. Проверяем флаги (последние 14 бит адреса)
            if (uint160(hookAddress) & 0x3FFF == flags) {
                return (hookAddress, salt);
            }
        }
        
        revert("HookMiner: Could not find salt. Increase loop limit.");
    }
}
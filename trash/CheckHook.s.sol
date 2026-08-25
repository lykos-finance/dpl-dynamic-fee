// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract CheckHook is Script {
    function run() external view {
        address hook = vm.envAddress("HOOK_ADDRESS_V5");
        
        console.log("Hook:", hook);
        
        uint160 flags = uint160(hook) & 0x3FFF;
        console.log("Flags:", flags == 0x0082 ? "OK" : "FAIL");
        
        uint256 size;
        assembly { size := extcodesize(hook) }
        console.log("Deployed:", size > 0 ? "YES" : "NO");
    }
}

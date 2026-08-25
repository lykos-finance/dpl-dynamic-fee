// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract CheckHookMainnet is Script {
    function run() external view {
        address hook = 0xF43b5192d166CeCeb64255672Ef159d0771cd080;
        
        console.log("=== Mainnet Hook Check ===");
        console.log("Address:", hook);
        
        uint160 flags = uint160(hook) & 0x3FFF;
        console.log("Flags (hex):", flags);
        console.log("Expected:    ", uint160(0x0082));
        
        bool hasBEFORE_SWAP = (flags & 0x80) != 0;
        bool hasAFTER_INIT = (flags & 0x02) != 0;
        
        console.log("BEFORE_SWAP (0x80):", hasBEFORE_SWAP);
        console.log("AFTER_INIT (0x02): ", hasAFTER_INIT);
        
        uint256 size;
        assembly { size := extcodesize(hook) }
        console.log("Code size:", size);
        
        if (size > 0) {
            console.log("Status: DEPLOYED on mainnet");
            if (!hasAFTER_INIT) {
                console.log("WARNING: Hook missing AFTER_INIT flag!");
                console.log("This hook was deployed without afterInitialize support");
            }
        } else {
            console.log("Status: NOT deployed");
        }
    }
}

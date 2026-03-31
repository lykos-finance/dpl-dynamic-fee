// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

contract WithdrawUSDTScript is Script {
    address internal constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant RECIPIENT = 0xE3a21743cDCEb8F4AA45F9393F5e41d3C3183e16;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(privateKey);
        uint256 amount = vm.envUint("USDT_AMOUNT");

        require(block.chainid == 1, "This script is for Ethereum mainnet only");

        uint256 senderBalance = IERC20Like(USDT_MAINNET).balanceOf(sender);
        require(senderBalance >= amount, "Insufficient USDT balance");

        console.log("=== USDT WITHDRAW SCRIPT ===");
        console.log("Sender:", sender);
        console.log("Recipient:", RECIPIENT);
        console.log("USDT:", USDT_MAINNET);
        console.log("Amount (raw, 6 decimals):", amount);

        vm.startBroadcast(privateKey);
        _safeTransfer(USDT_MAINNET, RECIPIENT, amount);
        vm.stopBroadcast();

        console.log("Transfer sent");
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "USDT transfer failed");
    }
}
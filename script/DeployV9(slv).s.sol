// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "../test/libraries/HookMiner.sol";
import {HookFactoryV8} from "./DeployV8(slv).s.sol";
import {VolatilityGuardHookV9} from "../src/dynamic-fee(slv-V9).sol";

/// @notice Deploys VolatilityGuardHookV9 on Ethereum mainnet.
///
/// Env:
///   PRIVATE_KEY
///   TREASURY     receives the 10% in ETH (default: the deployer). Cannot be changed later
///   INITIALIZER  wallet allowed to list tokens without a Chainlink price (default: the deployer).
///                Checked as tx.origin, so it works through the Uniswap interface. Cannot be changed later
contract DeployV9 is Script {
    address constant POOL_MANAGER      = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Tokens
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant UNI  = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant SHIB = 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Chainlink proxies, checked against the Chainlink Feed Registry
    address constant USDC_ETH = 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;
    address constant USDT_ETH = 0xEe9F2375b4bdF6387aa8265dD4FB8F16512A1d46;
    address constant DAI_ETH  = 0x773616E4d11A78F511299002da57A0a94577F1f4;
    address constant LINK_ETH = 0xDC530D9457755926550b59e8ECcdaE7624181557;
    address constant UNI_ETH  = 0xD6aA3D25116d8dA79Ea0246c4826EB951872e02e;
    address constant AAVE_ETH = 0x6Df09E975c830ECae5bd4eD9d90f3A95a4f88012;
    address constant SHIB_ETH = 0x8dD1CD88F43aF196ae478e91b9F5E4Ac69A97C61;
    address constant WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant BTC_USD  = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    // Heartbeat plus one hour of slack
    uint32 constant DAY_FEED  = 25 hours; // 24-hour heartbeat
    uint32 constant HOUR_FEED = 2 hours;  // 1-hour heartbeat

    function oracleList() public pure returns (VolatilityGuardHookV9.OracleConfig[] memory c) {
        c = new VolatilityGuardHookV9.OracleConfig[](8);
        c[0] = VolatilityGuardHookV9.OracleConfig(USDC, USDC_ETH, DAY_FEED, address(0), 0, false);
        c[1] = VolatilityGuardHookV9.OracleConfig(USDT, USDT_ETH, DAY_FEED, address(0), 0, false);
        c[2] = VolatilityGuardHookV9.OracleConfig(DAI,  DAI_ETH,  DAY_FEED, address(0), 0, false);
        c[3] = VolatilityGuardHookV9.OracleConfig(LINK, LINK_ETH, DAY_FEED, address(0), 0, false);
        c[4] = VolatilityGuardHookV9.OracleConfig(UNI,  UNI_ETH,  DAY_FEED, address(0), 0, false);
        c[5] = VolatilityGuardHookV9.OracleConfig(AAVE, AAVE_ETH, DAY_FEED, address(0), 0, false);
        c[6] = VolatilityGuardHookV9.OracleConfig(SHIB, SHIB_ETH, DAY_FEED, address(0), 0, false);
        // WBTC in ETH = WBTC/BTC * BTC/USD / ETH/USD
        c[7] = VolatilityGuardHookV9.OracleConfig(WBTC, WBTC_BTC, DAY_FEED, BTC_USD, HOUR_FEED, true);
    }

    function run() external {
        uint256 pk          = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(pk);
        address treasury    = vm.envOr("TREASURY", deployer);
        address initializer = vm.envOr("INITIALIZER", deployer);

        require(block.chainid == 1, "Wrong chain - need Ethereum mainnet");
        require(treasury != address(0) && initializer != address(0), "zero address");

        console.log("=== DeployV9 ===");
        console.log("Deployer:   ", deployer);
        console.log("Treasury:   ", treasury);
        console.log("Initializer:", initializer);

        vm.startBroadcast(pk);
        HookFactoryV8 factory = new HookFactoryV8();
        vm.stopBroadcast();
        console.log("Factory:    ", address(factory));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(POOL_MANAGER, treasury, CHAINLINK_ETH_USD, initializer, oracleList());
        (address predicted, bytes32 salt) =
            HookMiner.find(address(factory), flags, type(VolatilityGuardHookV9).creationCode, args);
        require(uint160(predicted) & uint160(0x3FFF) == flags, "Wrong flags");

        vm.startBroadcast(pk);
        address hook = factory.deploy(abi.encodePacked(type(VolatilityGuardHookV9).creationCode, args), salt);
        vm.stopBroadcast();
        require(hook == predicted, "Hook addr mismatch");
        require(VolatilityGuardHookV9(hook).initializer() == initializer, "Initializer mismatch");

        console.log("Hook:       ", hook);
        console.log("Salt:       ", vm.toString(salt));
        console.log("Payout threshold (wei):", VolatilityGuardHookV9(hook).payoutThreshold());
        console.log("\nConstructor args (for verification):");
        console.logBytes(args);
        console.log("\nAdd to .env:");
        console.log(string.concat("HOOK_ADDRESS_V9=", vm.toString(hook)));
    }
}

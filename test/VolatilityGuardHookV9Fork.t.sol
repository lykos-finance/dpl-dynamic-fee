// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {DeployV9} from "../script/DeployV9(slv).s.sol";
import {HookFactoryV8} from "../script/DeployV8(slv).s.sol";
import {InitPoolV8} from "../script/InitPoolV8(slv).s.sol";
import {InitPoolV8Token} from "../script/InitPoolV8Token(slv).s.sol";
import {BuyV8, SellV8} from "../script/SwapV8(slv).s.sol";
import {PoolPriceAligner} from "../src/PoolPriceAligner.sol";
import {VolatilityGuardHookV9} from "../src/dynamic-fee(slv-V9).sol";

interface IBal { function balanceOf(address) external view returns (uint256); }

/// @notice VolatilityGuardHookV9 with the real Chainlink feeds on a mainnet fork. Nothing is sent to mainnet.
contract VolatilityGuardHookV9ForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant VJDX = 0x47D8982457d52d3d59B87fE4913a07dEb764c4e5;

    // Keys derived here, never published: mainnet addresses with public keys carry EIP-7702 sweepers
    uint256 ownerPk = uint256(keccak256("V9 fork owner"));
    uint256 strangerPk = uint256(keccak256("V9 fork stranger"));
    address owner = vm.addr(ownerPk);
    address stranger = vm.addr(strangerPk);
    address treasury = address(uint160(uint256(keccak256("V9 fork treasury"))));

    VolatilityGuardHookV9 hook;

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), 0x800000, 60, IHooks(address(hook)));
    }

    function _price(PoolKey memory key) internal view returns (uint160 p) {
        (p,,,) = PM.getSlot0(key.toId());
    }

    /// @dev One test: the scripts read env vars set with vm.setEnv, which parallel tests would race on
    function test_fullFlowV9() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        vm.deal(owner, 10 ether);
        vm.deal(stranger, 10 ether);
        deal(USDC, stranger, 1_000e6);
        deal(VJDX, stranger, 100e18);
        deal(VJDX, owner, 100e18);

        _deploy();
        _strangerListsUsdcViaScript();
        _wbtcAtOneDollarIsRejected();
        _wbtcAtOraclePriceIsAccepted();
        _vjdxOnlyByInitializer();
        _movedEmptyPoolIsRestored();
    }

    function _deploy() internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(ownerPk)));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("INITIALIZER", vm.toString(owner));
        vm.recordLogs();
        new DeployV9().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == HookFactoryV8.HookDeployed.selector) {
                hook = VolatilityGuardHookV9(address(uint160(uint256(logs[i].topics[1]))));
            }
        }
        assertEq(hook.initializer(), owner);
        assertEq(hook.treasury(), treasury);
        console.log("hook", address(hook), "runtime bytes", address(hook).code.length);
    }

    /// Anyone can list an oracle token through the usual script, and the swaps work as in V8
    function _strangerListsUsdcViaScript() internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(strangerPk)));
        vm.setEnv("HOOK_ADDRESS_V8", vm.toString(address(hook)));
        vm.setEnv("LP_USDC_PER_SIDE", "100000000"); // $100
        vm.setEnv("LP_RANGE_BELOW_PCT", "50");
        vm.setEnv("LP_RANGE_ABOVE_PCT", "100");
        new InitPoolV8().run();
        PoolKey memory key = _key(USDC);
        assertGt(PM.getLiquidity(key.toId()), 0);

        vm.setEnv("SWAP_TOKEN", vm.toString(USDC));
        vm.setEnv("SWAP_AMOUNT", "1000000000000000");
        new BuyV8().run();
        vm.setEnv("SWAP_AMOUNT", "1000000");
        new SellV8().run();
        assertGt(hook.accruedTreasury(), 0);
    }

    /// A bot cannot list ETH/WBTC at $1 per bitcoin, not even through the trusted wallet
    function _wbtcAtOneDollarIsRejected() internal {
        PoolKey memory key = _key(WBTC);
        // $1 per BTC at ETH ~ $1800: 1 ETH buys ~1800 WBTC = 1800e8 units per 1e18 wei
        uint160 oneDollar = uint160(_sqrtX96(1800e8 * 1e18, 1e18 * 1e18));
        vm.prank(stranger, stranger);
        vm.expectRevert();
        PM.initialize(key, oneDollar);
        vm.prank(owner, owner);
        vm.expectRevert();
        PM.initialize(key, oneDollar);
        assertEq(_price(key), 0);
    }

    function _wbtcAtOraclePriceIsAccepted() internal {
        PoolKey memory key = _key(WBTC);
        uint160 fair = hook.oracleSqrtPriceX96(WBTC);
        vm.prank(stranger, stranger);
        PM.initialize(key, fair);
        assertEq(_price(key), fair);
        // ~1 BTC in ETH for the log: price = WBTC units per wei
        uint256 ethPerBtc = (uint256(1e8) << 192) / (uint256(fair) * uint256(fair)) ;
        console.log("WBTC listed, ETH per BTC (wei/1e8 units):", ethPerBtc);
    }

    /// A token without an oracle can only be listed by the initializer
    function _vjdxOnlyByInitializer() internal {
        vm.setEnv("TOKEN_ADDRESS", vm.toString(VJDX));
        vm.setEnv("TOKEN_PRICE_ETH", "47373764518461");
        vm.setEnv("TOKEN_LP_ETH", "1000000000000000");
        vm.setEnv("TOKEN_FULL_RANGE", "true");

        // A stranger cannot create the pool (a reverted script would leave its broadcast open, so call directly)
        PoolKey memory key = _key(VJDX);
        vm.prank(stranger, stranger);
        vm.expectRevert();
        PM.initialize(key, uint160(_sqrtX96(1e18, 47373764518461)));
        assertEq(_price(key), 0, "stranger could not list VJDX");

        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(ownerPk)));
        new InitPoolV8Token().run();
        assertGt(PM.getLiquidity(_key(VJDX).toId()), 0, "initializer listed VJDX");
    }

    /// An attacker moves an empty oracle pool for free; anyone restores it to Chainlink for free
    function _movedEmptyPoolIsRestored() internal {
        PoolKey memory key = _key(WBTC); // listed above, no liquidity
        uint160 fair = hook.oracleSqrtPriceX96(WBTC);
        PoolPriceAligner aligner = new PoolPriceAligner(PM);
        uint160 bad = uint160(uint256(fair) * 13 / 10); // ~70% off in price
        vm.prank(stranger, stranger);
        aligner.align{value: 1e12}(key, bad, 1e12);
        assertEq(_price(key), bad);

        uint256 before = stranger.balance;
        vm.prank(stranger, stranger);
        hook.alignToOracle(key);
        assertEq(_price(key), fair);
        assertEq(stranger.balance, before, "restoring cost nothing but gas");
    }

    function _sqrtX96(uint256 num, uint256 den) internal pure returns (uint256) {
        // sqrt(num / den) * 2^96
        uint256 x = (num << 96) / den;
        return _sqrt(x) << 48;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

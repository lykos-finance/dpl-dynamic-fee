// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {DeployV9} from "../script/DeployV9(slv).s.sol";
import {HookFactoryV8} from "../script/DeployV8(slv).s.sol";
import {InitPoolV9} from "../script/InitPoolV9(slv).s.sol";
import {BuyV9, SellV9} from "../script/SwapV9(slv).s.sol";
import {InitPoolUSDT, BuyUSDT, SellUSDT} from "../script/V9USDT(slv).s.sol";
import {VolatilityGuardHookV9} from "../src/dynamic-fee(slv-V9).sol";

interface IERC20S {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

/// @notice The V9 scripts against real mainnet contracts on a fork: native ETH and WETH pools (WETH as
///         currency0 with USDT, as currency1 with LINK), and USDT's approve quirks. Nothing is sent to
///         mainnet. One test: the scripts read env vars set with vm.setEnv.
contract ScriptsV9ForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    uint256 ownerPk = uint256(keccak256("scripts v9 owner"));
    uint256 strangerPk = uint256(keccak256("scripts v9 stranger"));
    address owner = vm.addr(ownerPk);
    address stranger = vm.addr(strangerPk);
    address treasury = address(uint160(uint256(keccak256("scripts v9 treasury"))));

    VolatilityGuardHookV9 hook;

    function _key(address token, bool useWeth) internal view returns (PoolKey memory) {
        address eth = useWeth ? WETH : address(0);
        (address c0, address c1) = eth < token ? (eth, token) : (token, eth);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0x800000, 60, IHooks(address(hook)));
    }

    function _as(uint256 pk) internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(pk)));
    }

    function test_scriptsV9() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        vm.deal(owner, 100 ether);
        vm.deal(stranger, 100 ether);
        deal(USDC, stranger, 100_000e6);
        deal(USDT, stranger, 100_000e6);
        deal(USDT, owner, 100_000e6);
        deal(LINK, owner, 10_000e18);

        _deploy();
        _nativeUsdcByStranger();
        _nativeUsdtByStrangerWithDirtyAllowance();
        _wethUsdtWethAsCurrency0();
        _wethLinkWethAsCurrency1();
    }

    function _deploy() internal {
        _as(ownerPk);
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
        vm.setEnv("HOOK_ADDRESS_V9", vm.toString(address(hook)));
        vm.setEnv("LP_ETH", "1000000000000000000"); // 1 ETH side
        vm.setEnv("LP_RANGE_BELOW_PCT", "20");
        vm.setEnv("LP_RANGE_ABOVE_PCT", "25");
        vm.setEnv("SWAP_SLIPPAGE_BPS", "100");
        assertEq(hook.weth(), WETH);
        assertEq(hook.baseFee(LINK), 2_500);
        assertEq(hook.baseFee(USDT), 500);
    }

    /// Native ETH / USDC: any wallet, oracle price
    function _nativeUsdcByStranger() internal {
        _as(strangerPk);
        vm.setEnv("USE_WETH", "false");
        vm.setEnv("TOKEN_ADDRESS", vm.toString(USDC));
        new InitPoolV9().run();
        assertGt(PM.getLiquidity(_key(USDC, false).toId()), 0, "ETH/USDC created by a stranger");

        vm.setEnv("SWAP_TOKEN", vm.toString(USDC));
        uint256 u0 = IERC20S(USDC).balanceOf(stranger);
        vm.setEnv("SWAP_AMOUNT", "10000000000000000"); // 0.01 ETH
        new BuyV9().run();
        assertGt(IERC20S(USDC).balanceOf(stranger), u0, "bought USDC");
        vm.setEnv("SWAP_AMOUNT", "5000000"); // 5 USDC
        new SellV9().run();
        console.log("ETH/USDC: created, bought, sold");
    }

    /// Native ETH / USDT through the USDT script, starting from a non-zero allowance to Permit2:
    /// a plain approve would revert here
    function _nativeUsdtByStrangerWithDirtyAllowance() internal {
        vm.prank(stranger);
        (bool ok,) = USDT.call(abi.encodeWithSelector(0x095ea7b3, PERMIT2, 1));
        require(ok);
        assertEq(IERC20S(USDT).allowance(stranger, PERMIT2), 1);

        _as(strangerPk);
        vm.setEnv("USE_WETH", "false");
        new InitPoolUSDT().run();
        assertGt(PM.getLiquidity(_key(USDT, false).toId()), 0, "ETH/USDT created");

        uint256 t0 = IERC20S(USDT).balanceOf(stranger);
        vm.setEnv("SWAP_AMOUNT", "10000000000000000");
        new BuyUSDT().run();
        assertGt(IERC20S(USDT).balanceOf(stranger), t0, "bought USDT");
        vm.setEnv("SWAP_AMOUNT", "5000000");
        new SellUSDT().run();
        console.log("ETH/USDT (separate script, dirty allowance): created, bought, sold");
    }

    /// WETH / USDT: WETH is currency0. Only the initializer creates it; WETH is wrapped from ETH
    function _wethUsdtWethAsCurrency0() internal {
        assertLt(uint160(WETH), uint160(USDT));
        _as(ownerPk);
        vm.setEnv("USE_WETH", "true");
        new InitPoolUSDT().run();
        PoolKey memory key = _key(USDT, true);
        assertEq(Currency.unwrap(key.currency0), WETH);
        assertGt(PM.getLiquidity(key.toId()), 0, "WETH/USDT created");

        uint256 before = hook.accruedTreasuryWeth();
        vm.setEnv("SWAP_AMOUNT", "10000000000000000");
        new BuyUSDT().run();
        vm.setEnv("SWAP_AMOUNT", "5000000");
        new SellUSDT().run();
        assertGt(hook.accruedTreasuryWeth(), before, "treasury share in WETH");
        console.log("WETH/USDT (WETH currency0): created by the initializer, bought, sold");
    }

    /// LINK / WETH: WETH is currency1, the oracle price is inverted for the pool
    function _wethLinkWethAsCurrency1() internal {
        assertGt(uint160(WETH), uint160(LINK));
        _as(ownerPk);
        vm.setEnv("USE_WETH", "true");
        vm.setEnv("TOKEN_ADDRESS", vm.toString(LINK));
        new InitPoolV9().run();
        PoolKey memory key = _key(LINK, true);
        assertEq(Currency.unwrap(key.currency1), WETH);
        assertGt(PM.getLiquidity(key.toId()), 0, "LINK/WETH created");

        vm.setEnv("SWAP_TOKEN", vm.toString(LINK));
        uint256 l0 = IERC20S(LINK).balanceOf(owner);
        vm.setEnv("SWAP_AMOUNT", "10000000000000000");
        new BuyV9().run();
        assertGt(IERC20S(LINK).balanceOf(owner), l0, "bought LINK with WETH");
        vm.setEnv("SWAP_AMOUNT", "1000000000000000000"); // 1 LINK
        new SellV9().run();
        console.log("LINK/WETH (WETH currency1): created by the initializer, bought, sold");
        console.log("Treasury accrued, ETH / WETH:", hook.accruedTreasury(), hook.accruedTreasuryWeth());
    }
}

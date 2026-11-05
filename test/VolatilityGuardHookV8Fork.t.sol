// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {DeployV8} from "../script/DeployV8(slv).s.sol";
import {InitPoolV8, AggregatorV3Interface} from "../script/InitPoolV8(slv).s.sol";
import {VolatilityGuardHookV8} from "../src/dynamic-fee(slv-V8).sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface INFT {
    function ownerOf(uint256) external view returns (address);
}

/// @notice Runs both deploy scripts against real mainnet contracts on a local fork. Nothing is sent to mainnet.
contract VolatilityGuardHookV8ForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Foundry's public default test key: replaces any PRIVATE_KEY from .env for this test
    uint256 constant TEST_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address deployer = vm.addr(TEST_PK);

    function test_fullFlow() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(TEST_PK)));
        vm.setEnv("SIGNER_A", vm.toString(address(0xA1)));
        vm.setEnv("SIGNER_B", vm.toString(address(0xA2)));

        address hook = _deployHook();
        assertEq(VolatilityGuardHookV8(payable(hook)).treasury(), deployer);

        vm.setEnv("HOOK_ADDRESS_V8", vm.toString(hook));
        vm.setEnv("LP_USDC_PER_SIDE", "100000000000"); // $100k per side
        vm.setEnv("LP_RANGE_BELOW_PCT", "50");
        vm.setEnv("LP_RANGE_ABOVE_PCT", "50");
        deal(USDC, deployer, 200_000e6);
        deal(WETH, deployer, 200 ether);

        uint256 tokenId = IPositionManager(POSITION_MANAGER).nextTokenId();
        new InitPoolV8().run();
        assertEq(INFT(POSITION_MANAGER).ownerOf(tokenId), deployer);

        PoolKey memory key = PoolKey(Currency.wrap(USDC), Currency.wrap(WETH), 0x800000, 60, IHooks(hook));
        _assertPoolPriceMatchesChainlink(key);
        _swapPaysTreasury(key);
        _deployerWithdrawsAlone(key, tokenId);

        InitPoolV8 again = new InitPoolV8();
        vm.expectRevert("Pool already initialized");
        again.run();
    }

    function _deployHook() internal returns (address hook) {
        vm.recordLogs();
        new DeployV8().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("HookDeployed(address,bytes32)")) {
                hook = address(uint160(uint256(logs[i].topics[1])));
            }
        }
        assertTrue(hook != address(0));
    }

    function _assertPoolPriceMatchesChainlink(PoolKey memory key) internal view {
        (uint160 sqrtPrice,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        (, int256 answer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        uint256 poolUsd8 = (1e20 << 96) / sqrtPrice * (1 << 96) / sqrtPrice;
        assertApproxEqRel(poolUsd8, uint256(answer), 1e15); // 0.1%
    }

    function _swapPaysTreasury(PoolKey memory key) internal {
        PoolSwapTest router = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        address trader = makeAddr("trader");
        deal(USDC, trader, 10_000e6);
        uint256 treasuryBefore = IERC20Min(WETH).balanceOf(deployer);

        vm.startPrank(trader);
        IERC20Min(USDC).approve(address(router), type(uint256).max);
        router.swap(
            key,
            IPoolManager.SwapParams(true, -1000e6, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();

        assertGt(IERC20Min(WETH).balanceOf(deployer), treasuryBefore);
    }

    function _deployerWithdrawsAlone(PoolKey memory key, uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, deployer);
        uint256 usdcBefore = IERC20Min(USDC).balanceOf(deployer);

        vm.prank(deployer);
        IPositionManager(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        assertGt(IERC20Min(USDC).balanceOf(deployer), usdcBefore);
    }
}

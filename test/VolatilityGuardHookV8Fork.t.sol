// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {DeployV8} from "../script/DeployV8(slv).s.sol";
import {InitPoolV8, AggregatorV3Interface} from "../script/InitPoolV8(slv).s.sol";
import {InitPoolV8Token} from "../script/InitPoolV8Token(slv).s.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
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
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Foundry's public default test key: replaces any PRIVATE_KEY from .env for this test
    uint256 constant TEST_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address deployer = vm.addr(TEST_PK);
    // No known private key: a makeAddr() address has a public key and on mainnet can carry an
    // EIP-7702 sweeper that forwards any ETH it receives
    address treasury = address(uint160(uint256(keccak256("VolatilityGuardHookV8 fork treasury"))));

    function test_fullFlow() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(TEST_PK)));
        vm.setEnv("TREASURY", vm.toString(treasury));

        address hook = _deployHook();
        assertEq(VolatilityGuardHookV8(hook).treasury(), treasury);

        vm.setEnv("HOOK_ADDRESS_V8", vm.toString(hook));
        vm.setEnv("LP_USDC_PER_SIDE", "100000000000"); // $100k per side
        vm.setEnv("LP_RANGE_BELOW_PCT", "50");
        vm.setEnv("LP_RANGE_ABOVE_PCT", "50");
        deal(USDC, deployer, 200_000e6);
        vm.deal(deployer, 200 ether);

        uint256 tokenId = IPositionManager(POSITION_MANAGER).nextTokenId();
        new InitPoolV8().run();
        assertEq(INFT(POSITION_MANAGER).ownerOf(tokenId), deployer);

        PoolKey memory key =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), 0x800000, 60, IHooks(hook));
        _assertPoolPriceMatchesChainlink(key);
        _swapsPayTreasuryInEth(key, VolatilityGuardHookV8(hook));
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

    /// @dev price = USDC units per ETH wei = usd8 / 1e20
    function _assertPoolPriceMatchesChainlink(PoolKey memory key) internal view {
        (uint160 sqrtPrice,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        (, int256 answer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        uint256 poolUsd8 = FullMath.mulDiv(uint256(sqrtPrice) * sqrtPrice, 1e20, 1 << 192);
        assertApproxEqRel(poolUsd8, uint256(answer), 1e15); // 0.1%
    }

    function _swapsPayTreasuryInEth(PoolKey memory key, VolatilityGuardHookV8 hook) internal {
        PoolSwapTest router = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        address trader = makeAddr("trader");
        deal(USDC, trader, 100_000e6);
        vm.deal(trader, 10 ether);

        vm.startPrank(trader, trader);
        IERC20Min(USDC).approve(address(router), type(uint256).max);

        // 1 ETH in: a small share accrues, below the $100 threshold
        router.swap{value: 1 ether}(
            key, IPoolManager.SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertGt(hook.accruedTreasury(), 0, "accrued in ETH");
        assertEq(treasury.balance, 0, "below the threshold");

        // $60k of USDC in moves the price far: ~2% fee, the ETH share passes $100 and is paid out
        router.swap(
            key, IPoolManager.SwapParams(false, -60_000e6, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        );
        vm.stopPrank();

        (, int256 answer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        uint256 paidUsd8 = (treasury.balance * uint256(answer)) / 1e18;
        console.log("treasury paid, USD:", paidUsd8 / 1e8);
        assertGe(paidUsd8, 100e8, "paid once above $100");
        assertEq(hook.accruedTreasury(), 1, "only 1 wei left");
        assertEq(IERC20Min(USDC).balanceOf(address(hook)) + address(hook).balance, 0, "hook holds no tokens");
    }

    function _deployerWithdrawsAlone(PoolKey memory key, uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        // The test key is public and its mainnet address forwards ETH away, so take to a keyless address
        address to = address(uint160(uint256(keccak256("VolatilityGuardHookV8 fork LP"))));
        params[1] = abi.encode(key.currency0, key.currency1, to);

        vm.prank(deployer);
        IPositionManager(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        assertGt(IERC20Min(USDC).balanceOf(to), 0, "USDC back");
        assertGt(to.balance, 0, "ETH back");
    }

    // --- ETH / any token (for example VJDX) ---

    /// @dev One test on purpose: vm.setEnv is shared by tests running in parallel
    function test_tokenPools() public {
        _tokenPoolFlow(18, "100000000000000", true); // 1 token = 0.0001 ETH, full range
        _tokenPoolFlow(6, "2000000000000000", false); // 1 token = 0.002 ETH, ±50%
        _vjdxFlow();
    }

    function _tokenPoolFlow(uint8 decimals, string memory priceE18, bool fullRange) internal {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(TEST_PK)));
        vm.setEnv("TREASURY", vm.toString(treasury));
        address hook = _deployHook();

        MockERC20 token = new MockERC20("Test Token", "TKN", decimals);
        token.mint(deployer, 1e12 * 10 ** decimals);
        vm.deal(deployer, 100 ether);

        vm.setEnv("HOOK_ADDRESS_V8", vm.toString(hook));
        vm.setEnv("TOKEN_ADDRESS", vm.toString(address(token)));
        vm.setEnv("TOKEN_PRICE_ETH", priceE18);
        vm.setEnv("TOKEN_LP_ETH", "10000000000000000000"); // 10 ETH
        vm.setEnv("TOKEN_FULL_RANGE", fullRange ? "true" : "false");

        uint256 tokenId = IPositionManager(POSITION_MANAGER).nextTokenId();
        new InitPoolV8Token().run();
        assertEq(INFT(POSITION_MANAGER).ownerOf(tokenId), deployer);

        PoolKey memory key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 0x800000, 60, IHooks(hook));
        (uint160 sqrtPrice,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        uint256 poolPriceE18 = FullMath.mulDiv(10 ** decimals, 1 << 192, uint256(sqrtPrice) * sqrtPrice);
        assertApproxEqRel(poolPriceE18, vm.parseUint(priceE18), 1e12, "start price");
        assertGt(IPoolManager(POOL_MANAGER).getLiquidity(key.toId()), 0, "position in range");

        // A swap both ways: the treasury share accrues in ETH only
        PoolSwapTest router = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        address trader = makeAddr("trader");
        vm.deal(trader, 1 ether);
        vm.startPrank(trader, trader);
        router.swap{value: 0.1 ether}(
            key, IPoolManager.SwapParams(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        token.approve(address(router), type(uint256).max);
        router.swap(
            key,
            IPoolManager.SwapParams(false, -int256(token.balanceOf(trader) / 2), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        assertGt(VolatilityGuardHookV8(hook).accruedTreasury(), 0, "ETH accrued");
        assertEq(token.balanceOf(hook), 0, "no token in the hook");

        InitPoolV8Token again = new InitPoolV8Token();
        vm.expectRevert("Pool already initialized");
        again.run();
    }

    // --- The real VJDX token ---

    address constant VJDX = 0x47D8982457d52d3d59B87fE4913a07dEb764c4e5;

    /// @dev Runs inside test_tokenPools: it uses the same TOKEN_* env
    function _vjdxFlow() internal {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        MockERC20 vjdx = MockERC20(VJDX);
        assertEq(vjdx.decimals(), 18);

        // No transfer fee and no balance changes on its own
        address a = makeAddr("a");
        address b = makeAddr("b");
        deal(VJDX, a, 10e18);
        vm.prank(a);
        vjdx.transfer(b, 4e18);
        assertEq(vjdx.balanceOf(b), 4e18, "received in full");
        assertEq(vjdx.balanceOf(a), 6e18, "sent exactly");

        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(TEST_PK)));
        vm.setEnv("TREASURY", vm.toString(treasury));
        address hook = _deployHook();
        deal(VJDX, deployer, 500e18);
        vm.deal(deployer, 100 ether);

        vm.setEnv("HOOK_ADDRESS_V8", vm.toString(hook));
        vm.setEnv("TOKEN_ADDRESS", vm.toString(VJDX));
        vm.setEnv("TOKEN_PRICE_ETH", "10000000000000000"); // test price only: 1 VJDX = 0.01 ETH
        vm.setEnv("TOKEN_LP_ETH", "1000000000000000000"); // 1 ETH and ~100 VJDX
        vm.setEnv("TOKEN_FULL_RANGE", "true");
        new InitPoolV8Token().run();

        PoolKey memory key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(VJDX), 0x800000, 60, IHooks(hook));
        PoolSwapTest router = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        address trader = makeAddr("trader");
        vm.deal(trader, 1 ether);
        vm.startPrank(trader, trader);
        router.swap{value: 0.01 ether}(
            key, IPoolManager.SwapParams(true, -0.01 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 got = vjdx.balanceOf(trader);
        assertGt(got, 0, "bought VJDX");
        vjdx.approve(address(router), type(uint256).max);
        router.swap(
            key, IPoolManager.SwapParams(false, -int256(got), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        );
        vm.stopPrank();
        assertEq(vjdx.balanceOf(trader), 0, "sold back");
        assertGt(VolatilityGuardHookV8(hook).accruedTreasury(), 0, "treasury share in ETH");
    }
}

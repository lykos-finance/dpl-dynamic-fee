// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployV9} from "../script/DeployV9(slv).s.sol";
import {PoolPriceAligner} from "../src/PoolPriceAligner.sol";
import {VolatilityGuardHookV9, IPriceFeed} from "../src/dynamic-fee(slv-V9).sol";

interface IERC20C {
    function approve(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice V9 against real Chainlink feeds and real Uniswap contracts on a mainnet fork. No env vars,
///         so the tests can run in parallel. Nothing is sent to mainnet.
contract VolatilityGuardHookV9CoverageTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant VJDX = 0x47D8982457d52d3d59B87fE4913a07dEb764c4e5;

    uint160 constant FLAGS_V9 = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 constant FLAGS_V8 = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address owner = address(uint160(uint256(keccak256("V9 cov owner"))));
    address stranger = address(uint160(uint256(keccak256("V9 cov stranger"))));
    address treasury = address(uint160(uint256(keccak256("V9 cov treasury"))));

    VolatilityGuardHookV9 hook;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        address at = address((uint160(uint256(keccak256("V9 cov hook"))) & ~uint160(0x3FFF)) | FLAGS_V9);
        deployCodeTo(
            "dynamic-fee(slv-V9).sol:VolatilityGuardHookV9",
            abi.encode(PM, treasury, ETH_USD, owner, new DeployV9().oracleList(), new DeployV9().feeList(), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            at
        );
        hook = VolatilityGuardHookV9(at);
        lpRouter = new PoolModifyLiquidityTest(PM);
        swapRouter = new PoolSwapTest(PM);
        vm.deal(owner, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    function _key(address token, address h) internal pure returns (PoolKey memory) {
        return PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), 0x800000, 60, IHooks(h));
    }

    function _price(PoolKey memory key) internal view returns (uint160 p) {
        (p,,,) = PM.getSlot0(key.toId());
    }

    function _usd(address feed) internal view returns (uint256 a) {
        (, int256 answer,,,) = IPriceFeed(feed).latestRoundData();
        a = uint256(answer);
    }

    function _scale(uint160 sp, uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(uint256(sp) * num / den);
    }

    /// All 8 oracle tokens: the hook's price matches the USD feeds, listing at it works, 5% off does not
    function test_allOracleTokens() public {
        VolatilityGuardHookV9.OracleConfig[] memory list = new DeployV9().oracleList();
        uint256 ethUsd = _usd(ETH_USD);
        address[8] memory usdFeeds = [
            address(0), address(0), address(0),
            0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c, // LINK/USD
            0x553303d460EE0afB37EdFf9bE42922D8FF63220e, // UNI/USD
            0x547a514d5e3769680Ce22B2361c10Ea13619e8a9, // AAVE/USD
            address(0),
            0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c  // BTC/USD (WBTC ~ BTC)
        ];
        for (uint256 i; i < list.length; ++i) {
            _checkOracleToken(list[i].token, usdFeeds[i], i < 3, ethUsd);
        }
    }

    function _checkOracleToken(address token, address usdFeed, bool stable, uint256 ethUsd) internal {
        uint160 sp = hook.oracleSqrtPriceX96(token);
        // USD per token = ETH per token * ETH/USD; ETH per token (1e18) = 10^dec * 2^192 / sp^2
        uint256 usd8 = FullMath.mulDiv(10 ** IERC20C(token).decimals(), 1 << 192, uint256(sp) * uint256(sp)) * ethUsd / 1e18;
        console.log(IERC20C(token).symbol(), "USD (1e8):", usd8);
        if (stable) assertApproxEqRel(usd8, 1e8, 0.02e18, "stablecoin within 2% of $1");
        if (usdFeed != address(0)) assertApproxEqRel(usd8, _usd(usdFeed), 0.03e18, "matches the USD feed");

        PoolKey memory key = _key(token, address(hook));
        vm.prank(stranger, stranger);
        vm.expectRevert();
        PM.initialize(key, _scale(sp, 1025, 1000)); // ~5% off in price
        vm.prank(stranger, stranger);
        PM.initialize(key, sp);
        assertEq(_price(key), sp);
    }

    /// The Uniswap interface path: PositionManager multicall initializePool + mint, by any wallet
    function test_uiPath_listAndDepositLink() public {
        PoolKey memory key = _key(LINK, address(hook));
        uint160 sp = hook.oracleSqrtPriceX96(LINK);
        deal(LINK, stranger, 1_000e18);
        uint256 tokenId = _uiMint(stranger, key, sp, 0.05 ether, true);
        assertEq(IERC721(address(POSM)).ownerOf(tokenId), stranger);
        assertGt(PM.getLiquidity(key.toId()), 0);
    }

    /// Emptied pool moved by an attacker: a UI deposit quoted at the moved price fails safely,
    /// alignToOracle fixes it, then the deposit works at the oracle price
    function test_uiPath_movedEmptyPool() public {
        PoolKey memory key = _key(LINK, address(hook));
        uint160 fair = hook.oracleSqrtPriceX96(LINK);
        vm.prank(stranger, stranger);
        PM.initialize(key, fair);

        PoolPriceAligner aligner = new PoolPriceAligner(PM);
        uint160 bad = _scale(fair, 110, 100); // ~21% off in price
        vm.prank(stranger);
        aligner.align{value: 1e12}(key, bad, 1e12);
        assertEq(_price(key), bad);

        deal(LINK, stranger, 1_000e18);
        // The interface quotes amounts at the pool's (moved) price
        uint256 snap = vm.snapshotState();
        bool ok;
        try this.uiMintExternal(stranger, key, bad, 0.05 ether, false) {
            ok = true;
        } catch {}
        if (ok) {
            // If it went through, the hook moved the pool first: the deposit is at the oracle price
            assertEq(_price(key), fair, "deposit went in at the oracle price");
            console.log("UI deposit quoted at the moved price: went through after the hook aligned the pool");
        } else {
            assertEq(_price(key), bad, "nothing changed");
            console.log("UI deposit quoted at the moved price: reverted, no funds lost");
        }
        vm.revertToState(snap);

        hook.alignToOracle(key);
        assertEq(_price(key), fair);
        _uiMint(stranger, key, fair, 0.05 ether, false);
        assertEq(_price(key), fair);
    }

    /// Known limit: a token without an oracle whose price left every position's range has no active
    /// liquidity, so only the initializer can add liquidity until the price comes back into a range
    function test_limit_noOraclePoolOutOfRange() public {
        PoolKey memory key = _key(VJDX, address(hook));
        uint160 sp = uint160(_sqrtE(1e18, 47373764518461));
        vm.prank(owner, owner);
        PM.initialize(key, sp);
        int24 tick = TickMath.getTickAtSqrtPrice(sp) / 60 * 60;
        deal(VJDX, owner, 100e18);
        // Narrow position: one tick spacing around the price
        _lp(owner, key, tick - 60, tick + 60, 1e18);
        assertGt(PM.getLiquidity(key.toId()), 0);

        // A buy pushes the price out of the narrow range
        deal(VJDX, stranger, 100e18);
        vm.prank(stranger);
        swapRouter.swap{value: 1 ether}(
            key, IPoolManager.SwapParams(true, -1 ether, TickMath.getSqrtPriceAtTick(tick - 600)),
            PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(PM.getLiquidity(key.toId()), 0, "price left the range");

        vm.startPrank(stranger, stranger);
        IERC20C(VJDX).approve(address(lpRouter), type(uint256).max);
        vm.expectRevert();
        lpRouter.modifyLiquidity{value: 1 ether}(key, IPoolManager.ModifyLiquidityParams(-887220, 887220, 1e15, 0), "");
        vm.stopPrank();
        console.log("limit confirmed: stranger cannot add to a no-oracle pool with no active liquidity");
    }

    /// Deposit gas: V8 vs V9 on the same ETH/USDC pool shape with the real feeds
    function test_gas_depositV8vsV9() public {
        address v8 = address((uint160(uint256(keccak256("V8 cov hook"))) & ~uint160(0x3FFF)) | FLAGS_V8);
        deployCodeTo("dynamic-fee(slv-V8).sol:VolatilityGuardHookV8", abi.encode(PM, treasury, ETH_USD), v8);
        uint160 sp = hook.oracleSqrtPriceX96(USDC);
        PoolKey memory k8 = _key(USDC, v8);
        PoolKey memory k9 = _key(USDC, address(hook));
        PM.initialize(k8, sp);
        vm.prank(stranger, stranger);
        PM.initialize(k9, sp);

        deal(USDC, address(this), 1_000_000e6);
        IERC20C(USDC).approve(address(lpRouter), type(uint256).max);
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams(-887220, 887220, 1e12, 0);
        lpRouter.modifyLiquidity{value: 10 ether}(k8, p, ""); // warm both pools' common slots once
        lpRouter.modifyLiquidity{value: 10 ether}(k9, p, "");

        uint256 g = gasleft();
        lpRouter.modifyLiquidity{value: 10 ether}(k8, p, "");
        uint256 g8 = g - gasleft();
        g = gasleft();
        lpRouter.modifyLiquidity{value: 10 ether}(k9, p, "");
        uint256 g9 = g - gasleft();
        console.log("deposit gas V8:", g8);
        console.log("deposit gas V9:", g9);
        console.log("extra for the oracle check:", g9 - g8);
    }

    // Helpers

    function uiMintExternal(address who, PoolKey memory key, uint160 quotedAt, uint256 ethAmount, bool init)
        external
        returns (uint256)
    {
        require(msg.sender == address(this));
        return _uiMint(who, key, quotedAt, ethAmount, init);
    }

    /// @dev What the Uniswap interface sends: [initializePool], mint quoted at `quotedAt` with 1% slippage,
    ///      settle, sweep
    function _uiMint(address who, PoolKey memory key, uint160 quotedAt, uint256 ethAmount, bool init)
        internal
        returns (uint256 tokenId)
    {
        (bytes[] memory calls, uint128 max0) = _uiCalls(who, key, quotedAt, ethAmount, init);
        tokenId = POSM.nextTokenId();
        address token = Currency.unwrap(key.currency1);
        vm.startPrank(who, who);
        IERC20C(token).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(token, address(POSM), type(uint160).max, uint48(block.timestamp + 3600));
        IMulticallC(address(POSM)).multicall{value: max0}(calls);
        vm.stopPrank();
    }

    /// @dev What the Uniswap interface sends: [initializePool], full-range mint quoted at `quotedAt`
    ///      with 1% slippage, settle, sweep
    function _uiCalls(address who, PoolKey memory key, uint160 quotedAt, uint256 ethAmount, bool init)
        internal
        view
        returns (bytes[] memory calls, uint128 max0)
    {
        bytes[] memory params = new bytes[](3);
        (params[0], max0) = _mintParams(who, key, quotedAt, ethAmount);
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, who);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        calls = new bytes[](init ? 2 : 1);
        if (init) calls[0] = abi.encodeWithSignature("initializePool((address,address,uint24,int24,address),uint160)", key, quotedAt);
        calls[init ? 1 : 0] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp + 60));
    }

    function _mintParams(address who, PoolKey memory key, uint160 quotedAt, uint256 ethAmount)
        internal
        pure
        returns (bytes memory encoded, uint128 max0)
    {
        (uint128 liq, uint128 m0, uint128 m1) = _amounts(quotedAt, ethAmount);
        max0 = m0;
        encoded = abi.encode(key, int24(-887220), int24(887220), uint256(liq), m0, m1, who, bytes(""));
    }

    function _amounts(uint160 quotedAt, uint256 ethAmount) internal pure returns (uint128 liq, uint128 m0, uint128 m1) {
        uint160 hi = TickMath.getSqrtPriceAtTick(887220);
        liq = LiquidityAmounts.getLiquidityForAmount0(quotedAt, hi, ethAmount);
        (uint256 a0, uint256 a1) =
            LiquidityAmounts.getAmountsForLiquidity(quotedAt, TickMath.getSqrtPriceAtTick(-887220), hi, liq);
        m0 = uint128(a0 * 101 / 100 + 1);
        m1 = uint128(a1 * 101 / 100 + 1);
    }

    function _lp(address who, PoolKey memory key, int24 lo, int24 hi, int256 liq) internal {
        vm.startPrank(who, who);
        IERC20C(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 10 ether}(key, IPoolManager.ModifyLiquidityParams(lo, hi, liq, 0), "");
        vm.stopPrank();
    }

    /// sqrt(num/den) * 2^96 for price = num/den token units per wei
    function _sqrtE(uint256 num, uint256 den) internal pure returns (uint256) {
        return _sqrt(FullMath.mulDiv(num, 1 << 192, den));
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

    receive() external payable {}
}

interface IERC721 {
    function ownerOf(uint256) external view returns (address);
}

interface IMulticallC {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

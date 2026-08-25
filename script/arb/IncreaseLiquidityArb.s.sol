// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
    function allowance(address, address) external view returns (uint256);
}

/// @notice Add more liquidity to an EXISTING position on Arbitrum (uses INCREASE_LIQUIDITY).
/// @dev ENV:
///   PRIVATE_KEY       — signer (must own TOKEN_ID)
///   HOOK_ADDRESS_ARB  — hook of the pool
///   TOKEN_ID          — existing LP NFT id
///   ADD_USDT_UNITS    — (optional) USDT in smallest units (6 dec). Default 5_000_000 = 5 USDT
///   ADD_WETH_WEI      — (optional) WETH in wei. Default 2e15 = 0.002 WETH (~$4.7)
contract IncreaseLiquidityArb is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Arbitrum One addresses
    address constant POOL_MANAGER      = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant POSITION_MANAGER  = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address constant PERMIT2           = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH              = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDT              = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    function run() public {
        require(block.chainid == 42161, "Wrong chain - need Arbitrum");

        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address hookAddr = vm.envAddress("HOOK_ADDRESS_ARB");
        uint256 tokenId  = vm.envUint("TOKEN_ID");
        uint256 addUSDT  = vm.envOr("ADD_USDT_UNITS", uint256(5_000_000));
        uint256 addWETH  = vm.envOr("ADD_WETH_WEI",   uint256(2_000_000_000_000_000));
        address deployer = vm.addr(pk);

        console.log("=== IncreaseLiquidityArb ===");
        console.log("Deployer:", deployer);
        console.log("TokenId: ", tokenId);
        console.log("ADD USDT:", addUSDT);
        console.log("ADD WETH:", addWETH);

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        IPositionManager pm  = IPositionManager(POSITION_MANAGER);

        // ── 1. Sort tokens ──
        address t0 = WETH;
        address t1 = USDT;
        if (t0 > t1) (t0, t1) = (t1, t0);
        // WETH < USDT → token0=WETH, token1=USDT

        // ── 2. PoolKey + read state ──
        PoolKey memory key = PoolKey(
            Currency.wrap(t0),
            Currency.wrap(t1),
            0x800000,
            60,
            IHooks(hookAddr)
        );
        PoolId poolId = key.toId();
        (uint160 sqrtCurrent, int24 currentTick, , ) = manager.getSlot0(poolId);
        require(sqrtCurrent != 0, "Pool not initialized");
        console.log("sqrtPrice:", uint256(sqrtCurrent));
        console.logInt(int256(currentTick));

        // ── 3. Tick range (hardcoded $2000-$2420, matches InitPoolArb and AddLiquidityArb) ──
        int24 tickLower = -200340;
        int24 tickUpper = -198360;
        uint160 sqrtLower = _getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = _getSqrtRatioAtTick(tickUpper);
        uint256 Q96 = 2**96;

        // ── 4. Compute liquidity (min of both constraints) ──
        uint128 L_weth = uint128(
            (addWETH * uint256(sqrtCurrent) * uint256(sqrtUpper)) /
            (Q96 * (uint256(sqrtUpper) - uint256(sqrtCurrent)))
        );
        uint128 L_usdt = uint128(
            (addUSDT * Q96) / (uint256(sqrtCurrent) - uint256(sqrtLower))
        );
        uint128 liquidity = L_weth < L_usdt ? L_weth : L_usdt;
        console.log("L_weth:  ", L_weth);
        console.log("L_usdt:  ", L_usdt);
        console.log("Using L: ", liquidity);

        // ── 5. Compute amounts with 5% buffer ──
        uint256 amount0Max = (uint256(liquidity) * Q96 *
            (uint256(sqrtUpper) - uint256(sqrtCurrent))) /
            (uint256(sqrtCurrent) * uint256(sqrtUpper));
        uint256 amount1Max = (uint256(liquidity) *
            (uint256(sqrtCurrent) - uint256(sqrtLower))) / Q96;
        amount0Max = amount0Max * 105 / 100;
        amount1Max = amount1Max * 105 / 100;
        console.log("amount0Max WETH:", amount0Max);
        console.log("amount1Max USDT:", amount1Max);

        require(IERC20Like(WETH).balanceOf(deployer) >= amount0Max, "Not enough WETH");
        require(IERC20Like(USDT).balanceOf(deployer) >= amount1Max, "Not enough USDT");

        vm.startBroadcast(pk);

        // ── 6. Approvals (idempotent) ──
        _ensureApprove(WETH, deployer, amount0Max);
        _ensureApprove(USDT, deployer, amount1Max);
        IAllowanceTransfer(PERMIT2).approve(WETH, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2).approve(USDT, POSITION_MANAGER, type(uint160).max, type(uint48).max);

        // ── 7. INCREASE_LIQUIDITY on tokenId ──
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            tokenId,
            uint256(liquidity),
            uint128(amount0Max),
            uint128(amount1Max),
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);

        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);

        vm.stopBroadcast();
        console.log("=== DONE - liquidity added to tokenId ===");
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "approve failed");
    }

    function _ensureApprove(address token, address owner, uint256 needed) internal {
        (bool okA, bytes memory d) = token.staticcall(
            abi.encodeWithSignature("allowance(address,address)", owner, PERMIT2)
        );
        require(okA, "allowance read failed");
        uint256 current = abi.decode(d, (uint256));
        if (current >= needed) return;
        if (current != 0) _safeApprove(token, PERMIT2, 0);
        _safeApprove(token, PERMIT2, type(uint256).max);
    }

    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= 887272, "T");
            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2     != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4     != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8     != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10    != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20    != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40    != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80    != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100   != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200   != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400   != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800   != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000  != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000  != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000  != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000  != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9)  >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604)   >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98)      >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2)           >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }
}

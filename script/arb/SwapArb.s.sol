// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function symbol() external view returns (string memory);
}

contract SwapRouterArb is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable owner;

    bytes4 private constant SYNC_SELECTOR   = bytes4(keccak256("sync(address)"));
    bytes4 private constant SETTLE_SELECTOR = bytes4(keccak256("settle()"));

    constructor(IPoolManager _manager) { manager = _manager; owner = msg.sender; }

    function swapFrom(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address inToken,
        uint256 amountIn
    ) external {
        _safeTransferFrom(inToken, msg.sender, address(this), amountIn);
        manager.unlock(abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, msg.sender));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "Not manager");
        (PoolKey memory key, bool zfo, int256 amt, uint160 limit, address recipient) =
            abi.decode(data, (PoolKey, bool, int256, uint160, address));

        if (limit == 0) {
            limit = zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zfo, amountSpecified: amt, sqrtPriceLimitX96: limit}),
            ""
        );

        if (delta.amount0() < 0) _pay(Currency.unwrap(key.currency0), uint256(uint128(-delta.amount0())));
        else if (delta.amount0() > 0) manager.take(key.currency0, recipient, uint256(uint128(delta.amount0())));

        if (delta.amount1() < 0) _pay(Currency.unwrap(key.currency1), uint256(uint128(-delta.amount1())));
        else if (delta.amount1() > 0) manager.take(key.currency1, recipient, uint256(uint128(delta.amount1())));

        return "";
    }

    function _pay(address t, uint256 a) internal {
        (bool s1, ) = address(manager).call(abi.encodeWithSelector(SYNC_SELECTOR, t));
        require(s1, "Sync fail");
        _safeTransfer(t, address(manager), a);
        (bool s2, ) = address(manager).call(abi.encodeWithSelector(SETTLE_SELECTOR));
        require(s2, "Settle fail");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer reverted");
        if (data.length > 0) require(abi.decode(data, (bool)), "transfer returned false");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        if (!ok) { assembly { revert(add(data, 32), mload(data)) } }
        if (data.length > 0) require(abi.decode(data, (bool)), "transferFrom returned false");
    }

    function withdraw(address token, address to) external {
        require(msg.sender == owner, "Not owner");
        uint256 bal = IERC20Like(token).balanceOf(address(this));
        if (bal > 0) _safeTransfer(token, to, bal);
    }
}

/// @notice Swap in the Arbitrum WETH/USDT pool with VolatilityGuardHookV4.
/// @dev ENV: PRIVATE_KEY, HOOK_ADDRESS_ARB, SWAP_DIR (buy/sell), AMOUNT_IN, MIN_OUT (optional),
///           ROUTER_ADDR_ARB (optional — reuse router)
contract SwapArb is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant WETH         = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDT         = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    struct Ctx {
        uint256 pk;
        address deployer;
        address hookAddr;
        bool isBuy;
        uint256 amountIn;
        uint256 minOut;
        address existingRouter;
        address inToken;
        address outToken;
        PoolKey key;
        PoolId poolId;
    }

    function run() public {
        require(block.chainid == 42161, "Wrong chain - need Arbitrum");
        Ctx memory c = _loadCtx();
        (uint160 sqrtBefore, int24 tickBefore, uint24 lpFeeBefore) = _before(c);

        uint256 inBal  = IERC20Like(c.inToken).balanceOf(c.deployer);
        uint256 outBal = IERC20Like(c.outToken).balanceOf(c.deployer);
        require(inBal >= c.amountIn, "Insufficient balance");

        _execute(c);

        (uint160 sqrtAfter, int24 tickAfter, , uint24 lpFeeAfter) =
            IPoolManager(POOL_MANAGER).getSlot0(c.poolId);

        console.log("----- AFTER -----");
        console.log("sqrtPrice:", uint256(sqrtAfter));
        console.logInt(int256(tickAfter));
        console.log("lpFee:", uint256(lpFeeAfter));
        console.logInt(int256(tickAfter) - int256(tickBefore));

        uint256 spent = inBal - IERC20Like(c.inToken).balanceOf(c.deployer);
        uint256 gained = IERC20Like(c.outToken).balanceOf(c.deployer) - outBal;
        console.log("Spent:   ", spent);
        console.log("Received:", gained);
        require(gained >= c.minOut, "Below MIN_OUT");

        sqrtBefore; lpFeeBefore; // silence unused
    }

    function _loadCtx() internal view returns (Ctx memory c) {
        c.pk = vm.envUint("PRIVATE_KEY");
        c.hookAddr = vm.envAddress("HOOK_ADDRESS_ARB");
        c.amountIn = vm.envUint("AMOUNT_IN");
        c.minOut = vm.envOr("MIN_OUT", uint256(0));
        c.existingRouter = vm.envOr("ROUTER_ADDR_ARB", address(0));
        c.deployer = vm.addr(c.pk);

        string memory dir = vm.envString("SWAP_DIR");
        c.isBuy = keccak256(bytes(dir)) == keccak256(bytes("buy"));
        require(c.isBuy || keccak256(bytes(dir)) == keccak256(bytes("sell")), "SWAP_DIR buy/sell");

        address t0 = WETH;
        address t1 = USDT;
        if (t0 > t1) (t0, t1) = (t1, t0);

        c.key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 0x800000, 60, IHooks(c.hookAddr));
        c.poolId = c.key.toId();

        bool zfo = !c.isBuy;
        c.inToken  = zfo ? t0 : t1;
        c.outToken = zfo ? t1 : t0;
    }

    function _before(Ctx memory c) internal view returns (uint160 s, int24 t, uint24 f) {
        (s, t, , f) = IPoolManager(POOL_MANAGER).getSlot0(c.poolId);
        require(s != 0, "Pool not initialized");
        console.log("=== SwapArb ===");
        console.log("Hook:", c.hookAddr);
        console.log("Dir:", c.isBuy ? "BUY WETH" : "SELL WETH");
        console.log("AmountIn:", c.amountIn);
        console.log("----- BEFORE -----");
        console.log("sqrtPrice:", uint256(s));
        console.logInt(int256(t));
        console.log("lpFee:", uint256(f));
    }

    function _execute(Ctx memory c) internal {
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        vm.startBroadcast(c.pk);

        SwapRouterArb router;
        if (c.existingRouter == address(0)) {
            router = new SwapRouterArb(manager);
            console.log("Deployed router:", address(router));
        } else {
            router = SwapRouterArb(c.existingRouter);
            require(router.owner() == c.deployer, "Router owner mismatch");
        }

        uint256 curAllow = IERC20Like(c.inToken).allowance(c.deployer, address(router));
        if (curAllow < c.amountIn) {
            if (curAllow != 0) _safeApprove(c.inToken, address(router), 0);
            _safeApprove(c.inToken, address(router), type(uint256).max);
        }

        router.swapFrom(c.key, !c.isBuy, -int256(c.amountIn), 0, c.inToken, c.amountIn);
        router.withdraw(c.outToken, c.deployer);

        vm.stopBroadcast();
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "approve failed");
    }
}

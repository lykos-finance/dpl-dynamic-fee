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
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Minimal router to perform a single swap on Uniswap v4 via unlock callback
contract SwapRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable owner;

    bytes4 private constant SYNC_SELECTOR   = bytes4(keccak256("sync(address)"));
    bytes4 private constant SETTLE_SELECTOR = bytes4(keccak256("settle()"));

    constructor(IPoolManager _manager) {
        manager = _manager;
        owner   = msg.sender;
    }

    /// @notice Pull input tokens from caller (needs approval) and swap atomically
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
            limit = zfo
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1;
        }

        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zfo,
                amountSpecified: amt,
                sqrtPriceLimitX96: limit
            }),
            ""
        );

        if (delta.amount0() < 0)
            _pay(Currency.unwrap(key.currency0), uint256(uint128(-delta.amount0())));
        else if (delta.amount0() > 0)
            manager.take(key.currency0, recipient, uint256(uint128(delta.amount0())));

        if (delta.amount1() < 0)
            _pay(Currency.unwrap(key.currency1), uint256(uint128(-delta.amount1())));
        else if (delta.amount1() > 0)
            manager.take(key.currency1, recipient, uint256(uint128(delta.amount1())));

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
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok, "transfer call reverted");
        if (data.length > 0) require(abi.decode(data, (bool)), "transfer returned false");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        if (!ok) {
            assembly { revert(add(data, 32), mload(data)) }
        }
        if (data.length > 0) require(abi.decode(data, (bool)), "transferFrom returned false");
    }

    /// @notice Recover stuck tokens (owner only)
    function withdraw(address token, address to) external {
        require(msg.sender == owner, "Not owner");
        uint256 bal = IERC20Like(token).balanceOf(address(this));
        if (bal > 0) _safeTransfer(token, to, bal);
    }
}

/// @notice Swap WETH <-> USDT in the VolatilityGuard pool, with slippage guard and fee logs
/// @dev ENV:
///   PRIVATE_KEY   — signer
///   HOOK_ADDRESS  — deployed hook (e.g. 0x22CAb54739D9CA681Bf9df4c48B16A065ced4080)
///   SWAP_DIR      — "buy" (USDT→WETH) or "sell" (WETH→USDT)
///   AMOUNT_IN     — exact input amount in token's smallest units
///                    buy:  USDT (6 dec),  e.g. 1000000      = 1 USDT
///                    sell: WETH (18 dec), e.g. 250000000000000 = 0.00025 WETH
///   MIN_OUT       — (optional) min output amount; default 0 (no slippage guard)
///   ROUTER_ADDR   — (optional) reuse existing router (must have swapFrom)
contract Swap is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH         = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT         = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Hook event signatures for log decoding
    bytes32 constant FEE_APPLIED_SIG = keccak256(
        "FeeApplied(bytes32,uint24,string,int24,int24,int24,uint256)"
    );
    bytes32 constant PANIC_ACTIVATED_SIG = keccak256(
        "PanicModeActivated(bytes32,int24,int24,int24,uint256,uint256)"
    );
    bytes32 constant PANIC_EXTENDED_SIG = keccak256(
        "PanicModeExtended(bytes32,uint256,uint256)"
    );

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
        Ctx memory c = _loadCtx();

        (uint160 sqrtBefore, int24 tickBefore, uint24 lpFeeBefore) = _before(c);

        uint256 inBalBefore  = IERC20Like(c.inToken).balanceOf(c.deployer);
        uint256 outBalBefore = IERC20Like(c.outToken).balanceOf(c.deployer);
        require(inBalBefore >= c.amountIn, "Insufficient balance");

        vm.recordLogs();
        _execute(c);

        (uint160 sqrtAfter, int24 tickAfter, , uint24 lpFeeAfter) =
            IPoolManager(POOL_MANAGER).getSlot0(c.poolId);

        _logAfter(c, sqrtBefore, tickBefore, lpFeeBefore, sqrtAfter, tickAfter, lpFeeAfter,
                  inBalBefore, outBalBefore);

        _logHookEvents(c.hookAddr);
        console.log("=== DONE ===");
    }

    function _loadCtx() internal view returns (Ctx memory c) {
        c.pk             = vm.envUint("PRIVATE_KEY");
        c.hookAddr       = vm.envAddress("HOOK_ADDRESS");
        c.amountIn       = vm.envUint("AMOUNT_IN");
        c.minOut         = vm.envOr("MIN_OUT", uint256(0));
        c.existingRouter = vm.envOr("ROUTER_ADDR", address(0));
        c.deployer       = vm.addr(c.pk);

        string memory dir = vm.envString("SWAP_DIR");
        c.isBuy = _strEq(dir, "buy");
        require(c.isBuy || _strEq(dir, "sell"), "SWAP_DIR must be 'buy' or 'sell'");

        address t0 = WETH;
        address t1 = USDT;
        if (t0 > t1) (t0, t1) = (t1, t0);

        c.key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 0x800000, 60, IHooks(c.hookAddr));
        c.poolId = c.key.toId();

        bool zfo = !c.isBuy;
        c.inToken  = zfo ? t0 : t1;
        c.outToken = zfo ? t1 : t0;
    }

    function _before(Ctx memory c)
        internal
        view
        returns (uint160 sqrtBefore, int24 tickBefore, uint24 lpFeeBefore)
    {
        (sqrtBefore, tickBefore, , lpFeeBefore) = IPoolManager(POOL_MANAGER).getSlot0(c.poolId);
        require(sqrtBefore != 0, "Pool not initialized");

        console.log("=== Swap ===");
        console.log("Deployer:", c.deployer);
        console.log("Hook:    ", c.hookAddr);
        console.logBytes32(PoolId.unwrap(c.poolId));

        console.log("----- BEFORE SWAP -----");
        console.log("  sqrtPriceX96:", uint256(sqrtBefore));
        console.logInt(int256(tickBefore));
        console.log("  lpFee (raw): ", uint256(lpFeeBefore));
        _logFeePercent("  lpFee (bps): ", lpFeeBefore);
        console.log("  Direction:   ", c.isBuy ? "BUY WETH" : "SELL WETH");
        console.log("  In:  ", IERC20Like(c.inToken).symbol(),  c.amountIn);
        console.log("  Out: ", IERC20Like(c.outToken).symbol(), "(min:", c.minOut);
    }

    function _execute(Ctx memory c) internal {
        vm.startBroadcast(c.pk);

        SwapRouter router;
        if (c.existingRouter == address(0)) {
            router = new SwapRouter(IPoolManager(POOL_MANAGER));
            console.log("  Deployed router:", address(router));
        } else {
            router = SwapRouter(c.existingRouter);
            require(router.owner() == c.deployer, "Router owner mismatch");
            console.log("  Using router:   ", address(router));
        }

        // Approve MAX once per router (idempotent, avoids 2-tx reset dance)
        uint256 curAllow = IERC20Like(c.inToken).allowance(c.deployer, address(router));
        if (curAllow < c.amountIn) {
            if (curAllow != 0) _safeApprove(c.inToken, address(router), 0);
            _safeApprove(c.inToken, address(router), type(uint256).max);
        }
        router.swapFrom(c.key, !c.isBuy, -int256(c.amountIn), 0, c.inToken, c.amountIn);
        router.withdraw(c.outToken, c.deployer);

        vm.stopBroadcast();
    }

    function _logAfter(
        Ctx memory c,
        uint160 sqrtBefore,
        int24 tickBefore,
        uint24 lpFeeBefore,
        uint160 sqrtAfter,
        int24 tickAfter,
        uint24 lpFeeAfter,
        uint256 inBalBefore,
        uint256 outBalBefore
    ) internal view {
        console.log("----- AFTER SWAP -----");
        console.log("  sqrtPriceX96:", uint256(sqrtAfter));
        console.logInt(int256(tickAfter));
        console.log("  lpFee (raw): ", uint256(lpFeeAfter));
        _logFeePercent("  lpFee (bps): ", lpFeeAfter);

        console.log("----- FEE DIFF -----");
        console.log("  before->after raw:", uint256(lpFeeBefore), "->", uint256(lpFeeAfter));

        int256 tickDelta = int256(tickAfter) - int256(tickBefore);
        console.log("  Tick delta:");
        console.logInt(tickDelta);

        uint256 inSpent  = inBalBefore  - IERC20Like(c.inToken).balanceOf(c.deployer);
        uint256 outGain  = IERC20Like(c.outToken).balanceOf(c.deployer) - outBalBefore;
        console.log("  Spent:   ", inSpent);
        console.log("  Received:", outGain);
        require(outGain >= c.minOut, "Slippage: below MIN_OUT");

        sqrtBefore; // silence unused warning
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev USDT requires zero allowance before nonzero — reset only if current != 0.
    function _safeApprove(address token, address spender, uint256 amount) internal {
        uint256 current = IERC20Like(token).allowance(msg.sender, spender);
        if (current != 0 && current != amount) {
            (bool ok1, bytes memory d1) = token.call(
                abi.encodeWithSignature("approve(address,uint256)", spender, 0)
            );
            require(ok1 && (d1.length == 0 || abi.decode(d1, (bool))), "approve reset failed");
        }
        if (current != amount) {
            (bool ok2, bytes memory d2) = token.call(
                abi.encodeWithSignature("approve(address,uint256)", spender, amount)
            );
            require(ok2 && (d2.length == 0 || abi.decode(d2, (bool))), "approve failed");
        }
    }

    /// @dev Fee from dynamic-fee hook: raw value is pips (1e6 scale). 500 = 0.05%, 20000 = 2%.
    function _logFeePercent(string memory label, uint24 feeRaw) internal pure {
        // percent * 10000 for 4-decimal precision in integer logs
        uint256 bpsX100 = uint256(feeRaw) * 10000 / 1_000_000; // basis points
        console.log(label, bpsX100, "bps");
    }

    /// @dev Walk recorded logs, decode hook's fee-related events.
    function _logHookEvents(address hookAddr) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console.log("----- HOOK EVENTS -----");
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.emitter != hookAddr) continue;
            bytes32 sig = log.topics[0];

            if (sig == FEE_APPLIED_SIG) {
                (uint24 fee, string memory reason, int24 curTick, int24 refTick, int24 dTick, ) =
                    abi.decode(log.data, (uint24, string, int24, int24, int24, uint256));
                console.log("  [FeeApplied] fee:", uint256(fee), "reason:", reason);
                console.log("    curTick:");   console.logInt(int256(curTick));
                console.log("    refTick:");   console.logInt(int256(refTick));
                console.log("    tickDelta:"); console.logInt(int256(dTick));
                count++;
            } else if (sig == PANIC_ACTIVATED_SIG) {
                console.log("  [PanicModeActivated] !!!");
                count++;
            } else if (sig == PANIC_EXTENDED_SIG) {
                console.log("  [PanicModeExtended]");
                count++;
            }
        }
        if (count == 0) console.log("  (no hook events captured)");
    }
}

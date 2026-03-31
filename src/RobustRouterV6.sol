// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract RobustRouterV6 is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    bytes4 private constant TRANSFER_FROM_SELECTOR =
        bytes4(keccak256("transferFrom(address,address,uint256)"));

    IPoolManager public immutable manager;
    address public immutable owner;

    // ── Events ───────────────────────────────────────────────────────────────

    event LiquidityAdded(address indexed user, int24 tickLower, int24 tickUpper, int256 amount, int128 delta0, int128 delta1);
    event LiquidityRemoved(address indexed user, int24 tickLower, int24 tickUpper, int256 amount, int128 delta0, int128 delta1);
    event Swapped(address indexed user, bool zeroForOne, int256 amountSpecified, int128 delta0, int128 delta1);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    // ── Errors ───────────────────────────────────────────────────────────────

    error Expired();
    error SlippageExceeded();

    constructor(IPoolManager _manager) {
        manager = _manager;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    // ── External functions ───────────────────────────────────────────────────

    /// @notice Add liquidity with slippage protection.
    /// @param amount0Max Maximum token0 the user is willing to pay.
    /// @param amount1Max Maximum token1 the user is willing to pay.
    function addLiquidity(
        PoolKey memory key,
        int24 tl,
        int24 tu,
        int256 amount,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external checkDeadline(deadline) {
        manager.unlock(abi.encode(uint8(1), key, tl, tu, amount, msg.sender, amount0Max, amount1Max));
    }

    /// @notice Remove liquidity with slippage protection.
    /// @param amount0Min Minimum token0 the user expects to receive.
    /// @param amount1Min Minimum token1 the user expects to receive.
    function removeLiquidity(
        PoolKey memory key,
        int24 tl,
        int24 tu,
        int256 amount,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external checkDeadline(deadline) {
        manager.unlock(abi.encode(uint8(2), key, tl, tu, amount, msg.sender, amount0Min, amount1Min));
    }

    /// @notice Swap with explicit amount and slippage protection.
    /// @param amountSpecified Negative = exact input, positive = exact output.
    /// @param sqrtPriceLimitX96 Price limit (slippage control).
    /// @param amountOutMin Minimum output (for exact-input) or amountInMax (for exact-output).
    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint256 amountOutMin,
        uint256 deadline
    ) external checkDeadline(deadline) {
        manager.unlock(abi.encode(uint8(3), key, zeroForOne, amountSpecified, sqrtPriceLimitX96, msg.sender, amountOutMin));
    }

    /// @notice Withdraw residual tokens from router (owner only).
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        uint256 toWithdraw = amount;
        if (amount == type(uint256).max) {
            (bool okBal, bytes memory balData) = token.staticcall(
                abi.encodeWithSignature("balanceOf(address)", address(this))
            );
            require(okBal && balData.length >= 32, "Balance read failed");
            toWithdraw = abi.decode(balData, (uint256));
        }
        require(toWithdraw > 0, "Zero amount");
        _safeTransfer(token, to, toWithdraw);
        emit TokenWithdrawn(token, to, toWithdraw);
    }

    // ── Callback ─────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "Only Manager");

        uint8 action = abi.decode(data, (uint8));
        BalanceDelta delta;
        PoolKey memory key;
        address user;

        if (action == 1) {
            // --- ADD LIQUIDITY ---
            int24 tl; int24 tu; int256 amount;
            uint256 amount0Max; uint256 amount1Max;
            (, key, tl, tu, amount, user, amount0Max, amount1Max) =
                abi.decode(data, (uint8, PoolKey, int24, int24, int256, address, uint256, uint256));

            (delta, ) = manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({
                tickLower: tl,
                tickUpper: tu,
                liquidityDelta: amount,
                salt: bytes32(uint256(uint160(user)))
            }), "");

            // Slippage check: user must not pay more than expected
            if (delta.amount0() < 0 && uint256(uint128(-delta.amount0())) > amount0Max) revert SlippageExceeded();
            if (delta.amount1() < 0 && uint256(uint128(-delta.amount1())) > amount1Max) revert SlippageExceeded();

            emit LiquidityAdded(user, tl, tu, amount, delta.amount0(), delta.amount1());

        } else if (action == 2) {
            // --- REMOVE LIQUIDITY ---
            int24 tl; int24 tu; int256 amount;
            uint256 amount0Min; uint256 amount1Min;
            (, key, tl, tu, amount, user, amount0Min, amount1Min) =
                abi.decode(data, (uint8, PoolKey, int24, int24, int256, address, uint256, uint256));

            (delta, ) = manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({
                tickLower: tl,
                tickUpper: tu,
                liquidityDelta: -amount,
                salt: bytes32(uint256(uint160(user)))
            }), "");

            // Slippage check: user must receive at least expected
            uint256 got0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
            uint256 got1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
            if (got0 < amount0Min || got1 < amount1Min) revert SlippageExceeded();

            emit LiquidityRemoved(user, tl, tu, amount, delta.amount0(), delta.amount1());

        } else if (action == 3) {
            // --- SWAP ---
            bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; uint256 amountOutMin;
            (, key, zeroForOne, amountSpecified, sqrtPriceLimitX96, user, amountOutMin) =
                abi.decode(data, (uint8, PoolKey, bool, int256, uint160, address, uint256));

            delta = manager.swap(key, IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }), "");

            // Slippage check: for exact-input (amountSpecified < 0), check output >= amountOutMin
            if (amountSpecified < 0) {
                uint256 amountOut = zeroForOne
                    ? (delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0)
                    : (delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0);
                if (amountOut < amountOutMin) revert SlippageExceeded();
            }

            emit Swapped(user, zeroForOne, amountSpecified, delta.amount0(), delta.amount1());
        }

        // ── Settlement ───────────────────────────────────────────────────────

        if (delta.amount0() < 0) {
            _settle(key.currency0, user, uint256(uint128(-delta.amount0())));
        } else if (delta.amount0() > 0) {
            manager.take(key.currency0, user, uint256(uint128(delta.amount0())));
        }

        if (delta.amount1() < 0) {
            _settle(key.currency1, user, uint256(uint128(-delta.amount1())));
        } else if (delta.amount1() > 0) {
            manager.take(key.currency1, user, uint256(uint128(delta.amount1())));
        }

        return "";
    }

    // ── Internal functions ───────────────────────────────────────────────────

    /// @dev Pull tokens from payer via transferFrom (approve model).
    function _settle(Currency currency, address payer, uint256 amount) internal {
        address token = Currency.unwrap(currency);

        manager.sync(currency);

        (bool s1, bytes memory d1) = token.call(
            abi.encodeWithSelector(TRANSFER_FROM_SELECTOR, payer, address(manager), amount)
        );
        require(s1 && (d1.length == 0 || abi.decode(d1, (bool))), "TransferFrom failed");

        manager.settle();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }
}

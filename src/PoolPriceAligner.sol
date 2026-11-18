// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

interface IERC20Pay {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Moves a Uniswap v4 pool to a target price with one price-limited swap. In a pool with no
///         active liquidity this costs nothing but gas: the swap only moves the price.
///
/// The caller pays at most `maxIn` of the input currency (native ETH as msg.value, an ERC-20 through
/// an approval to this contract) and receives any output. The call reverts unless the pool ends
/// exactly at the target, so a pool with liquidity in the way and too small a `maxIn` is left alone.
///
/// No owner, no storage: funds only pass through within one call.
contract PoolPriceAligner is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error NotInitialized();
    error TargetNotReached();
    error RefundFailed();

    event Aligned(bytes32 indexed poolId, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96, int128 amount0, int128 amount1);

    struct CallbackData {
        PoolKey key;
        uint160 target;
        uint256 maxIn;
        address payer;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function align(PoolKey calldata key, uint160 targetSqrtPriceX96, uint256 maxIn) external payable {
        (uint160 current,,,) = poolManager.getSlot0(key.toId());
        if (current == 0) revert NotInitialized();

        BalanceDelta delta;
        if (current != targetSqrtPriceX96) {
            delta = abi.decode(
                poolManager.unlock(abi.encode(CallbackData(key, targetSqrtPriceX96, maxIn, msg.sender))),
                (BalanceDelta)
            );
        }
        (uint160 finalPrice,,,) = poolManager.getSlot0(key.toId());
        if (finalPrice != targetSqrtPriceX96) revert TargetNotReached();
        emit Aligned(PoolId.unwrap(key.toId()), current, finalPrice, delta.amount0(), delta.amount1());

        // Unused native ETH goes back to the caller
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            if (!ok) revert RefundFailed();
        }
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory d = abi.decode(raw, (CallbackData));

        (uint160 current,,,) = poolManager.getSlot0(d.key.toId());
        bool zeroForOne = d.target < current;
        BalanceDelta delta = poolManager.swap(
            d.key, IPoolManager.SwapParams(zeroForOne, -int256(d.maxIn), d.target), ""
        );

        _settle(d.key.currency0, delta.amount0(), d.payer);
        _settle(d.key.currency1, delta.amount1(), d.payer);
        return abi.encode(delta);
    }

    /// @dev Negative: we owe the pool. Positive: the pool owes the payer
    function _settle(Currency currency, int128 amount, address payer) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                require(IERC20Pay(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), owed), "pay failed");
                poolManager.settle();
            }
        } else if (amount > 0) {
            poolManager.take(currency, payer, uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}

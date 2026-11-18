// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {VolatilityGuardHookV9} from "../src/dynamic-fee(slv-V9).sol";

interface IERC20V9 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IWETH9 {
    function deposit() external payable;
}

/// @notice Shared pieces of the V9 scripts: pool keys for native ETH and WETH pools (WETH on either
///         side by address order), prices in the pool's orientation, and token approvals that also work
///         for USDT (no return value, no change of a non-zero allowance without resetting it to 0).
abstract contract V9Common is Script {
    address constant POOL_MANAGER     = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH             = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT             = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    int24 constant TICK_SPACING = 60;

    /// @dev A hook pool: `ethIs0` tells whether the ETH side (native ETH or WETH) is currency0
    struct Pair {
        PoolKey key;
        address token;
        address ethSide; // address(0) for native ETH, WETH otherwise
        bool ethIs0;
        uint8 decimals;
    }

    function _pair(address hook, address token, bool useWeth) internal view returns (Pair memory p) {
        require(token != address(0) && token != WETH, "Bad token");
        p.token = token;
        p.ethSide = useWeth ? WETH : address(0);
        p.ethIs0 = p.ethSide < token; // native ETH (0) is always below; WETH sorts by address
        (address c0, address c1) = p.ethIs0 ? (p.ethSide, token) : (token, p.ethSide);
        p.key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook));
        p.decimals = IERC20V9(token).decimals();
        if (useWeth) require(VolatilityGuardHookV9(hook).weth() == WETH, "Hook has WETH pools disabled");
    }

    /// @dev Pool sqrtPriceX96 for `priceE18` (wei per whole token) in this pool's orientation:
    ///      ETH side currency0 -> token units per wei, ETH side currency1 -> wei per token unit
    function _sqrtFromPrice(Pair memory p, uint256 priceE18) internal pure returns (uint160 sp) {
        uint256 ratioX192 = p.ethIs0
            ? FullMath.mulDiv(10 ** p.decimals, 1 << 192, priceE18)
            : FullMath.mulDiv(priceE18, 1 << 192, 10 ** p.decimals);
        sp = uint160(_sqrt(ratioX192));
        require(sp > TickMath.MIN_SQRT_PRICE && sp < TickMath.MAX_SQRT_PRICE, "Price out of range");
    }

    /// @dev The token's price in wei per whole token: the hook's Chainlink price if it has one,
    ///      otherwise TOKEN_PRICE_ETH from the environment
    function _priceE18(address hook, Pair memory p) internal view returns (uint256 priceE18, bool fromOracle) {
        try VolatilityGuardHookV9(hook).oracleSqrtPriceX96(p.token) returns (uint160 sp) {
            // oracle orientation: token units per wei = 10^dec / priceE18
            return (FullMath.mulDiv(10 ** p.decimals, 1 << 192, uint256(sp) * uint256(sp)), true);
        } catch {
            priceE18 = vm.envUint("TOKEN_PRICE_ETH");
            require(priceE18 > 0, "TOKEN_PRICE_ETH not set and the token has no live oracle");
        }
    }

    /// @dev approve that works for USDT-style tokens: tolerates no return value and resets a non-zero
    ///      allowance to 0 before setting a new one
    function _safeApprove(address token, address owner, address spender, uint256 amount) internal {
        uint256 current = IERC20V9(token).allowance(owner, spender);
        if (current >= amount) return;
        if (current != 0) _approveCall(token, spender, 0);
        _approveCall(token, spender, amount);
    }

    function _approveCall(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "approve failed");
    }

    /// @dev token -> Permit2 -> spender, for `amount` until `expiration`
    function _approveViaPermit2(address token, address owner, address spender, uint256 amount, uint48 expiration)
        internal
    {
        _safeApprove(token, owner, PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(token, spender, uint160(amount), expiration);
    }

    /// @dev Wraps native ETH into WETH if the wallet holds less WETH than `needed`
    function _wrapShortfall(address owner, uint256 needed) internal {
        uint256 have = IERC20V9(WETH).balanceOf(owner);
        if (have < needed) IWETH9(WETH).deposit{value: needed - have}();
    }

    function _floorToSpacing(int24 tick) internal pure returns (int24) {
        int24 q = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) q -= 1;
        return q * TICK_SPACING;
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

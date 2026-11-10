# VolatilityGuardHookV8: how to run

A Uniswap v4 hook for the USDC/WETH pool on Ethereum mainnet. The swap fee follows volatility and ranges from 0.01% to 2%. 90% of it goes to LPs and 10% is sent back to the swapper (`tx.origin`) in the same transaction. The hook keeps nothing and has no owner, admin or treasury.

## How it works

| Price deviation from the anchor | Charged | LPs | Rebate to `tx.origin` | Swapper's net cost |
|---|---|---|---|---|
| Up to 20 ticks (~0.2%) | 0.01% | 0.009% | 0.001% | 0.009% |
| 20 to 200 ticks | Linear increase | 90% of it | 10% of it | 90% of it |
| 200 ticks or more (~2%) | 2% | 1.8% | 0.2% | 1.8% |

- The anchor catches up with the current tick based on time (`ANCHOR_PERIOD` = 300 seconds), not on the number of swaps.
- A swap also pays for its own price impact, so a large swap gets a high fee itself.
- All fee parameters are constants. They cannot be changed after deployment: that takes a new hook, a new pool and a liquidity migration.
- Nobody has any rights over the hook: there is no pause, no fee change and no access to liquidity.
- Every LP, including the deployer, is paid by the same rules: the LP share is split pro rata to the liquidity that is in range at the time of the swap. Fees accrue in the position and are paid out automatically, together with the liquidity, when the position is decreased or closed. No separate claim is needed.
- If Uniswap enables the protocol fee (up to 0.1%), it is charged on top.
- The rebate is paid in the unspecified token of the swap (the output token for an exact-input swap) to `tx.origin`, not to the router. With a smart wallet, a relayer or a solver, `tx.origin` is whoever sent the transaction, so they get the rebate. Arbitrage bots get it too. Router slippage checks see the full fee, since the rebate arrives as a separate transfer. If the transfer to `tx.origin` fails, the rebate is simply not charged and the swap still goes through.

## Files

| File | Purpose |
|---|---|
| `src/dynamic-fee(slv-V8).sol` | The hook |
| `script/DeployV8(slv).s.sol` | Deploys the factory and the hook |
| `script/InitPoolV8(slv).s.sol` | Creates the pool and the first position |
| `test/VolatilityGuardHookV8.t.sol` | Unit tests |
| `test/VolatilityGuardHookV8Fork.t.sol` | Full flow on a mainnet fork |

## Installation

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/lykos-finance/dpl-dynamic-fee.git
cd dpl-dynamic-fee
git submodule update --init --recursive
```

Run all Foundry commands with the `v8` profile.

```bash
export FOUNDRY_PROFILE=v8
```

## Testing

```bash
# Unit tests
forge test --match-path test/VolatilityGuardHookV8.t.sol

# Deployment, pool creation, a swap and a withdrawal on a mainnet fork. Nothing is sent to the network
forge test --match-path test/VolatilityGuardHookV8Fork.t.sol
```

The fork test uses `MAINNET_RPC_URL`, or a public RPC if the variable is not set.

## `.env` setup

The `.env` file is not committed.

```bash
PRIVATE_KEY=0x...          # deployer wallet, owns the first position
MAINNET_RPC_URL=https://...

# After deploying the hook
HOOK_ADDRESS_V8=0x...

# Optional
LP_USDC_PER_SIDE=2500000   # USDC per side, 6 decimals. Defaults to $2.50
LP_RANGE_BELOW_PCT=50      # range around the current ETH price, %
LP_RANGE_ABOVE_PCT=50
```

## Deployment

Without `--broadcast`, a command only simulates the transactions. Always run the simulation first.

```bash
set -a; source .env; set +a

# 1. Simulate and deploy the hook
forge script "script/DeployV8(slv).s.sol:DeployV8" --rpc-url "$MAINNET_RPC_URL"
forge script "script/DeployV8(slv).s.sol:DeployV8" --rpc-url "$MAINNET_RPC_URL" --broadcast
```

Save the printed address as `HOOK_ADDRESS_V8` in `.env`. The deployer wallet must hold USDC and WETH (WETH specifically, not ETH).

```bash
set -a; source .env; set +a

# 2. Simulate and create the pool
forge script "script/InitPoolV8(slv).s.sol:InitPoolV8" --rpc-url "$MAINNET_RPC_URL"
forge script "script/InitPoolV8(slv).s.sol:InitPoolV8" --rpc-url "$MAINNET_RPC_URL" --broadcast
```

The script takes the starting price from Chainlink ETH/USD and creates the pool together with the first position in one transaction. The position NFT goes to the deployer wallet.

## Liquidity depth

The fee depends on how far a swap itself moves the price, so with thin liquidity almost every swap pays a lot. On a fork, a $1,000 swap with $100,000 per side and a ±50% range paid about 0.44% before the fee split was changed. It has not been measured since. With the default settings ($2.50 per side), even a small swap is charged about 2% and gets 0.2% back. Choose the amount and range before launch.

## Withdrawing liquidity

The position NFT sits in your wallet, and its owner can withdraw it through `PositionManager`. The accrued LP fees are paid in the same transaction. The fork test covers this withdrawal with a direct contract call. How the pool appears in the Uniswap interface has not been tested.

## Limitations

- Nothing can be fixed after deployment: a bug or a bad fee threshold means a new hook, a new pool and moving the liquidity.
- The contract has not had an external audit, and the fee thresholds have not been tested against historical market data.
- These scripts have not been used for a mainnet deployment. They have only been tested on a fork and in tests.

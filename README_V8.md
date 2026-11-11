# VolatilityGuardHookV8: how to run

A Uniswap v4 hook for pools of native ETH against any token on Ethereum mainnet. The swap fee follows volatility and ranges from 0.01% to 2%. 90% of it goes to the pool's LPs and 10% to the treasury, always in ETH. Anyone can create a pool with the hook, and every pool pays the same 10%. The hook has no owner or admin.

## How it works

| Price deviation from the anchor | Fee | LPs | Treasury (in ETH) |
|---|---|---|---|
| Up to 20 ticks (~0.2%) | 0.01% | 0.009% | 0.001% |
| 20 to 200 ticks | Linear increase | 90% of it | 10% of it |
| 200 ticks or more (~2%) | 2% | 1.8% | 0.2% |

- The anchor catches up with the current tick based on time (`ANCHOR_PERIOD` = 300 seconds), not on the number of swaps.
- A swap also pays for its own price impact, so a large swap gets a high fee itself.
- Only dynamic-fee pools whose `currency0` is native ETH can use the hook. A pool with WETH or without ETH cannot be created.
- Every LP, including the deployer, is paid by the same rules: the LP share is split pro rata to the liquidity that is in range at the time of the swap. Fees accrue in the position and are paid out together with the liquidity when the position is decreased or closed.
- The treasury share of all pools accrues in the hook as ERC-6909 claims in the PoolManager (`accruedTreasury()`). Once it exceeds $100 worth of ETH, the swap that crosses the threshold sends it to the treasury. 1 wei stays behind so the next accrual is cheaper. The threshold in ETH (`payoutThreshold()`) is set from Chainlink ETH/USD at deployment and refreshed at each payout, not on every swap.
- When a swap specifies an exact ETH amount (ETH in for an exact-input swap, ETH out for an exact-output swap), the treasury share can only be taken before the swap, at the fee in force then. The extra fee for that swap's own price move comes in the other token and goes to the LPs in full.
- The treasury address is fixed at deployment and can never be changed. If it cannot receive ETH, swaps still go through and the share keeps accruing in the hook, with no way to redirect it.
- All fee parameters are constants. Nobody can change fees, pause swaps or touch liquidity.
- If Uniswap enables the protocol fee (up to 0.1%), it is charged on top.

## Files

| File | Purpose |
|---|---|
| `src/dynamic-fee(slv-V8).sol` | The hook |
| `script/DeployV8(slv).s.sol` | Deploys the factory and the hook |
| `script/InitPoolV8(slv).s.sol` | Creates the ETH/USDC pool and the first position |
| `script/InitPoolV8Token(slv).s.sol` | Creates an ETH/token pool, for example ETH/VJDX |
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
TREASURY=0x...             # receives the 10% in ETH. Defaults to the deployer. Cannot be changed later

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

Save the printed address as `HOOK_ADDRESS_V8` in `.env`. The deployer wallet must hold USDC and native ETH (not WETH), plus ETH for gas.

```bash
set -a; source .env; set +a

# 2. Simulate and create the pool
forge script "script/InitPoolV8(slv).s.sol:InitPoolV8" --rpc-url "$MAINNET_RPC_URL"
forge script "script/InitPoolV8(slv).s.sol:InitPoolV8" --rpc-url "$MAINNET_RPC_URL" --broadcast
```

The script creates the native ETH/USDC pool. It takes the starting price from Chainlink ETH/USD and creates the pool together with the first position in one transaction. Unused ETH is returned in the same call. The position NFT goes to the deployer wallet.

## ETH / token pools (for example ETH/VJDX)

`script/InitPoolV8Token(slv).s.sol` creates a native ETH pool against any plain ERC-20 with the deployed hook and mints the first full-range or ±% position. There is no oracle for such tokens, so you set the starting price yourself.

```bash
TOKEN_ADDRESS=0x47D8982457d52d3d59B87fE4913a07dEb764c4e5   # VJDX
TOKEN_PRICE_ETH=$(cast to-wei 0.01)   # price of 1 token in ETH, 18 decimals
TOKEN_LP_ETH=$(cast to-wei 1)         # ETH for the position; the token amount follows from the price
TOKEN_FULL_RANGE=true                 # or false with TOKEN_RANGE_BELOW_PCT / TOKEN_RANGE_ABOVE_PCT
```

```bash
forge script "script/InitPoolV8Token(slv).s.sol:InitPoolV8Token" --rpc-url "$MAINNET_RPC_URL"
forge script "script/InitPoolV8Token(slv).s.sol:InitPoolV8Token" --rpc-url "$MAINNET_RPC_URL" --broadcast
```

Tokens with a transfer fee or a rebasing balance do not work with Uniswap v4 accounting: the simulation then fails. The fork test checks the real VJDX contract: no transfer fee, pool creation and swaps both ways.

## Liquidity depth

The fee depends on how far a swap itself moves the price, so with thin liquidity almost every swap pays a lot. On a fork, a $1,000 swap into a USDC/WETH pool with $100,000 per side and a ±50% range paid about 0.44%. The ETH/USDC pool has not been measured. With the default settings ($2.50 per side), even a small swap pays about 2%. Choose the amount and range before launch.

## Withdrawing liquidity

The position NFT sits in your wallet, and its owner can withdraw it through `PositionManager`. The accrued LP fees are paid in the same transaction. The fork test covers this withdrawal with a direct contract call. How the pool appears in the Uniswap interface has not been tested.

## Limitations

- Nothing can be fixed after deployment: a bug, a bad fee threshold or a lost treasury key means a new hook, a new pool and moving the liquidity.
- Use a treasury address whose key has never been public. On mainnet, addresses with known keys (such as the Foundry test accounts) carry EIP-7702 sweepers that forward any ETH they receive.
- The contract has not had an external audit, and the fee thresholds have not been tested against historical market data.
- These scripts have not been used for a mainnet deployment. They have only been tested on a fork and in tests.

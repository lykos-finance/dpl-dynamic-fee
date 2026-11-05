# VolatilityGuardHookV8: how to run

A Uniswap v4 hook for the USDC/WETH pool on Ethereum mainnet. The swap fee follows volatility and ranges from 0.01% to 2%. 10% of the fee goes straight to the treasury address, and LPs receive the rest.

## How it works

| Price deviation from the anchor | Fee |
|---|---|
| Up to 20 ticks (~0.2%) | 0.01% |
| 20 to 200 ticks | Linear increase |
| 200 ticks or more (~2%) | 2% |

- The anchor catches up with the current tick based on time (`ANCHOR_PERIOD` = 300 seconds), not on the number of swaps.
- A swap also pays for its own price impact, so a large swap gets a high fee itself.
- All fee parameters are constants. They cannot be changed after deployment: that takes a new hook, a new pool and a liquidity migration.
- There is no pause: nobody can stop swaps.
- If Uniswap enables the protocol fee (up to 0.1%), a trader pays at most 2.098%.
- If the transfer to the treasury fails, the swap still goes through and the share stays in the hook. `sweepToTreasury(currency)`, which anyone can call, sends it to the treasury address.

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
PRIVATE_KEY=0x...          # deployer wallet, which also receives the 10% and owns the position
MAINNET_RPC_URL=https://...
SIGNER_A=0x...             # multisig signers, two different addresses
SIGNER_B=0x...

# After deploying the hook
HOOK_ADDRESS_V8=0x...

# Optional
LP_USDC_PER_SIDE=2500000   # USDC per side, 6 decimals. Defaults to $2.50
LP_RANGE_BELOW_PCT=50      # range around the current ETH price, %
LP_RANGE_ABOVE_PCT=50
```

The hook address depends on the signers, so choose them before deploying. Avoid using the deployer address as a signer: if its key leaks, the treasury address cannot be changed without the second signer.

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

The fee depends on how far a swap itself moves the price, so with thin liquidity almost every swap pays a lot. On a fork, a $1,000 swap with $100,000 per side and a ±50% range paid about 0.44%. With the default settings ($2.50 per side), even a small swap pays about 2%. Choose the amount and range before launch.

## Withdrawing liquidity

No multisig is needed: the position NFT sits in your wallet, and its owner can withdraw it through `PositionManager`. The fork test covers this withdrawal with a direct contract call. How the pool appears in the Uniswap interface has not been tested.

## Changing the treasury address

This is the multisig's only action. One signer proposes, and the other confirms and executes, using separate keys.

```bash
HOOK=$HOOK_ADDRESS_V8
NEW=0x...

# Signer 1: propose
cast send $HOOK "proposeSetTreasury(address)" $NEW --rpc-url "$MAINNET_RPC_URL" --private-key <signer 1 key>

# Signer 2, within 30 minutes of the proposal: confirm
cast send $HOOK "confirmAndExecuteSetTreasury(address)" $NEW --rpc-url "$MAINNET_RPC_URL" --private-key <signer 2 key>

# Signer 2, 15 to 45 minutes after confirming: execute (same function)
cast send $HOOK "confirmAndExecuteSetTreasury(address)" $NEW --rpc-url "$MAINNET_RPC_URL" --private-key <signer 2 key>
```

If a deadline passes, the call reverts with `ProposalExpired`: create a new proposal.

## Limitations

- Signers cannot be replaced. Without either of them the treasury address can no longer be changed, but swaps and liquidity are not affected.
- One signer can reset a confirmation by proposing again, and so block a treasury change.
- The contract has not had an external audit, and the fee thresholds have not been tested against historical market data.
- These scripts have not been used for a mainnet deployment. They have only been tested on a fork and in tests.

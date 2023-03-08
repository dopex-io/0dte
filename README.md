# 0DTE options

Buyers get access to long option positions for 1 day upto 10% otm with set strike increments (matching deribit/bybit).

Writers deposit 50% USDC and WETH.

ERC-4626 LP tokens for LPs continously accruing base and quote assets with anytime withdrawals subject to available liquidity.

- Next day expiry (8am gmt)
- Upto X% OTM strikes with Y% strike increments. So for say ETH/USDC, it would be 10% OTM strikes with \$25 strike increments
- Writers deposit 50% base, 50% quote tokens (zap-in in ui if they have only 1) and sell covered calls/puts
- Writers get write tokens (ERC4626) that accrue pnl which can be withdrawn at anytime constrained by available liquidity
- Keepers expire positions

## Development

> (Optional) Setup the `.env` file with the vars mentioned in the `.env.sample` file.

### Compiling

```bash
yarn compile
```

### Running tests

Run all tests like this:

```bash
yarn test
```

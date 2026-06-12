# FeeCompounder Hook Specification

Version: `1.0.0`  
Target: UHI9 Hookathon, Hook 5 of 8  
Stack: Uniswap v4, Foundry, Reactive Lasna legacy endpoint

## Overview

FeeCompounder is an intelligent fee compounding hook. It accumulates a backed slice of LP fee income, emits every reserve update to Reactive Network, and lets a Reactive Smart Contract decide whether a compound action is economically sensible.

The decision engine checks:

1. pending fees exceed `minThreshold`
2. observed `block.basefee` is below `gasCeiling`
3. the pool is outside `cooldownBlocks`
4. an approved route exists
5. the route with the highest cached APY is selected

## Architecture

```text
LP / fee reporter
  -> FeeCompounderHook
  -> FeesAccrued(poolId, fees, totalPending, gasPrice, blockNumber)
  -> FeeCompounderRSC on Lasna
  -> Callback(destChainId, hook, triggerCompoundFromReactive(sender, key, route))
  -> Hook verifies callback proxy and RVM sender
  -> Hook deposits reserve into whitelisted yield route
```

## Hook Permissions

Enabled:

- `afterAddLiquidity`
- `beforeRemoveLiquidity`
- `afterSwap`

Disabled:

- `beforeSwap`
- `beforeSwapReturnDelta`
- `afterSwapReturnDelta`
- liquidity return-delta hooks

The conservative permission set is intentional. The hook observes v4 pool events and manages backed fee reserves, but it does not use high-risk return-delta hooks in this version.

## Storage

`PoolAccounting` stores:

- `totalShares`
- `totalAssets0`
- `totalAssets1`
- `pendingFees0`
- `pendingFees1`
- `routeShares0`
- `routeShares1`
- `lastCompoundBlock`
- `activeYieldRoute`
- `initialized`

LP state:

- `lpShares[poolId][lp]`
- `lpEntryBlock[poolId][lp]`

Access control:

- `owner`
- `feeReporter`
- `callbackProxy`
- `reactiveSender`
- `directCompoundCaller`
- `whitelistedAdapters`

## Events

`FeesAccrued(bytes32 indexed poolId, uint256 amount0, uint256 amount1, uint256 totalPending0, uint256 totalPending1, uint256 gasPrice, uint256 blockNumber)`

`CompoundExecuted(bytes32 indexed poolId, address indexed route, uint256 amount0Compounded, uint256 amount1Compounded, uint256 newTotalAssets0, uint256 newTotalAssets1, uint256 blockNumber)`

`SharesMinted(bytes32 indexed poolId, address indexed lp, uint256 sharesIssued, uint256 assets0, uint256 assets1)`

`SharesBurned(bytes32 indexed poolId, address indexed lp, uint256 sharesBurned, uint256 assets0, uint256 assets1)`

## Share Math

On first deposit:

```text
shares = assets0 + assets1
deadShares = 1000
lpShares = shares - deadShares
```

On later deposits:

```text
shares = (assets * totalShares) / (totalAssets + pendingFees)
```

On withdrawal:

```text
amount0 = shares * (totalAssets0 + pendingFees0) / totalShares
amount1 = shares * (totalAssets1 + pendingFees1) / totalShares
```

Dead shares reduce first-depositor inflation attacks.

## Fee Accrual

`reportFees(key, rawFee0, rawFee1)` is restricted to `feeReporter`.

It transfers:

```text
fee0 = rawFee0 * compoundFeeBps / 10000
fee1 = rawFee1 * compoundFeeBps / 10000
```

Then it emits `FeesAccrued` with `block.basefee` and `block.number`.

## RSC Logic

The RSC subscribes on Lasna:

```text
chain id: destination chain id
contract: hook address
topic0: keccak256("FeesAccrued(bytes32,uint256,uint256,uint256,uint256,uint256,uint256)")
topic1-topic3: REACTIVE_IGNORE
```

For every matching log:

1. decode total pending, gas price, emitted block
2. require pool key preconfigured by admin
3. skip if below threshold
4. skip if gas too high
5. skip if inside cooldown
6. choose max APY of Aave, Morpho, Pool
7. emit legacy `Callback`

## Reactive Auth

The destination hook accepts live callbacks only through:

```solidity
function triggerCompoundFromReactive(address sender, PoolKey calldata key, address route) external
```

It requires:

```text
msg.sender == callbackProxy
sender == reactiveSender
```

This follows the explicit legacy RVM identity pattern from the integration guide.

## Adapters

Adapters implement `IYieldRoute`:

- `deposit(token, amount) -> shares`
- `withdraw(token, shares) -> amount`
- `currentAPY(token) -> apyBps`
- `name()`

The bundled adapters are managed route adapters suitable for tests, demos, and hackathon deployments. Production Aave/Morpho adapters should replace the internal custody logic with direct protocol calls once target-chain route addresses are finalized.

## Configuration

| Parameter | Default |
| --- | ---: |
| `minCompoundThreshold` | `1 ether` |
| `gasPriceCeiling` | `30 gwei` |
| `cooldownBlocks` | `300` |
| `maxHoldBlocks` | `7200` |
| `compoundFeeBps` | `1000` |

## Failure Modes

| Scenario | Behavior |
| --- | --- |
| RSC unavailable | Fees remain pending; max-hold force-compound can use default route |
| Gas above ceiling | RSC skips until cheaper event |
| Pool unconfigured in RSC | RSC skips and emits reason |
| Adapter not whitelisted | Hook reverts before moving funds |
| Callback spoof | Hook reverts unless proxy and sender both match |

## Demo Flow

1. deploy hook and adapters
2. LP deposits backed demo inventory
3. fee reporter transfers fee reserve
4. hook emits `FeesAccrued`
5. RSC evaluates gates
6. RSC emits callback with explicit sender
7. hook compounds into selected route
8. LP withdraws principal plus reserve value

## Production Work Remaining

- Replace managed demo adapters with protocol-specific Aave and Morpho adapters for the final target chain.
- Wire fee reserve reporting to the selected v4 fee-capture mechanism.
- Run live Reactive callback proof on the exact destination chain and callback proxy.
- Run fork tests against deployed PoolManager and token routes.

# Aeternum Core

**Aeternum Core** is the protocol layer powering autonomous, non-custodial smart wallet vaults with automated recovery.

It enables users to define inactivity conditions and a recovery address. If inactivity persists beyond a chosen threshold, assets are automatically transferred—without custodians, intermediaries, or manual intervention.

---

## Overview

Aeternum introduces a new primitive for crypto ownership: **continuity**.

Traditional wallets assume constant user availability. Aeternum Core ensures that ownership persists even when the user becomes inactive.

---

## Core Features

- **Non-Custodial Vaults**  
  Users retain full control of their assets at all times.

- **Inactivity-Based Triggers**  
  Configurable inactivity periods initiate automated recovery.

- **Automated Execution**  
  Smart contracts integrate with decentralized automation (e.g. Chainlink) to trigger actions trustlessly.

- **Recovery Mechanism**  
  Funds are transferred to a predefined backup address after inactivity conditions are met.

- **No Backdoors**  
  Immutable logic. No admin overrides.

---

## Architecture

```
src/
├── RecoveryManager.sol              ← Core contract
└── interfaces/
    ├── IRecoveryManager.sol         ← Full interface (events, errors, structs, functions)
    └── AutomationCompatibleInterface.sol  ← Inlined Chainlink interface

test/
├── unit/
│   └── RecoveryManager.t.sol        ← Unit + fuzz + invariant tests
└── mocks/
    └── ReentrantAttacker.sol        ← Security test helper

script/
├── Deploy.s.sol                     ← Deployment + post-deploy checks
└── HelperConfig.s.sol               ← Network-aware config resolver
```

---

## Trust Model

| Who          | Can do                                              | Cannot do                              |
|--------------|-----------------------------------------------------|----------------------------------------|
| User         | register, deposit, withdraw, ping, cancel, config   | Access other users' funds              |
| Treasury     | Withdraw accumulated subscription fees              | Touch user recovery balances           |
| Chainlink    | Call `performUpkeep` when conditions are met        | Alter any config or redirect funds     |
| Anyone       | Call `checkUpkeep` (read-only)                      | Trigger recovery before period elapses |

---

## Quick Start

### 1. Install dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

### 2. Set environment variables

```bash
cp .env.example .env
# Fill in SEPOLIA_RPC_URL, MAINNET_RPC_URL, ETHERSCAN_API_KEY
```

### 3. Run tests

```bash
# Full test suite
forge test -vv

# With gas report
forge test --gas-report

# Fuzz tests only
forge test --match-test testFuzz -vv

# Invariant tests only
forge test --match-test invariant -vv

# Single test
forge test --match-test test_performUpkeep_executesRecovery -vvvv
```

### 4. Check coverage

```bash
forge coverage --report lcov
```

### 5. Static analysis

```bash
# Install slither: pip install slither-analyzer
slither src/RecoveryManager.sol

# Install solhint: npm install -g solhint
solhint src/RecoveryManager.sol
```

### 6. Deploy to Sepolia

```bash
# Dry run first (no --broadcast)
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL -vvvv

# Live deploy + Etherscan verification
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

---

## Chainlink Automation Setup

After deployment:

1. Go to [automation.chain.link](https://automation.chain.link)
2. Register a new **Custom Logic** upkeep
3. Set the target contract to your deployed `RecoveryManager` address
4. For `checkData`, encode pagination: `abi.encode(uint256(0), uint256(10))`
5. Fund the upkeep with LINK

For large user counts, register multiple upkeeps with different `checkData` windows:
- Upkeep 1: `abi.encode(0, 10)` — indices 0–9
- Upkeep 2: `abi.encode(10, 10)` — indices 10–19
- etc.

---

## Constants

| Constant                    | Value    | Description                              |
|-----------------------------|----------|------------------------------------------|
| `MIN_INACTIVITY_PERIOD_FREE`  | 180 days | Free tier minimum                        |
| `MIN_INACTIVITY_PERIOD_PREMIUM` | 30 days | Premium tier minimum                   |
| `MAX_INACTIVITY_PERIOD`       | 3650 days | Hard ceiling (10 years)                |
| `SUBSCRIPTION_DURATION`       | 30 days  | Premium subscription window              |
| `PREMIUM_MONTHLY_FEE`         | 0.005 ETH | Required for Premium registration/renewal |
| `MAX_BATCH_SIZE`              | 10       | Max wallets per `performUpkeep` call     |

---

## Security Considerations

- **Reentrancy**: All ETH-transferring functions are guarded by `ReentrancyGuard` + CEI pattern.
- **No admin backdoors**: Treasury can only withdraw subscription fees, not user balances.
- **Stale `performData`**: `_executeRecovery` re-validates all conditions; stale entries silently skip.
- **Swap-and-pop safety**: `_removeFromRegistry` uses 1-indexed mappings to handle concurrent batch removals correctly.
- **Integer overflow**: Solidity ^0.8 reverts on overflow natively.
- **Direct ETH transfers**: `receive()` explicitly reverts with `RecoveryManager__DirectTransferNotAllowed`.

---

## Audit Checklist

- [ ] Reentrancy on all external ETH transfer paths
- [ ] Access control: `onlyRegistered`, `onlyTreasury`
- [ ] CEI pattern enforced in `_executeRecovery`, `withdraw`, `withdrawAll`, `cancelRecovery`, `withdrawSubscriptionFees`
- [ ] Integer arithmetic (Solidity ^0.8 safe)
- [ ] `_removeFromRegistry` swap-and-pop correctness under batch removal
- [ ] `checkUpkeep` pagination boundary conditions
- [ ] Subscription fee accounting (separate from user balances)
- [ ] `receive()` prevents accidental ETH lock

---

## License

MIT

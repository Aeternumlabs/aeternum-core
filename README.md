# Aeternum Core

[![Lint](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/lint.yml/badge.svg)](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/lint.yml) 
[![Tests](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/test.yml/badge.svg)](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

A trustless, non-custodial smart wallet vault with built-in automated ETH recovery.

Aeternum Core lets users store ETH in a self-sovereign vault, send and receive funds like a normal wallet, and configure a backup address with an inactivity timer. If the user goes silent beyond their chosen period — lost keys, death, incapacitation — Chainlink Automation transfers their ETH to the backup address automatically. No custodians. No admin backdoors. Just code.

## Table of Contents

- [Documentation](#documentation)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Trust Model](#trust-model)
- [How It Works](#how-it-works)
- [Constants](#constants)
- [Dependencies](#dependencies)
- [Quickstart](#quickstart)
- [Development](#development)
- [Chainlink Automation Setup](#chainlink-automation-setup)
- [Security](#security)
- [License](#license)

## Documentation

- [Aeternum Core Overview](#how-it-works)
- [Chainlink Automation Docs](https://docs.chain.link/chainlink-automation)
- [Foundry Book](https://book.getfoundry.sh)

## Architecture

Aeternum Core is a single-contract architecture. Each registered wallet has its own isolated vault within the contract — balances are tracked individually, never pooled. Chainlink Automation nodes monitor all registered vaults off-chain and execute recovery on-chain only when inactivity conditions are met.

```
AeternumVault
├── User Vault (per address)
│   ├── balance          — ETH held in escrow
│   ├── backupAddress    — recovery destination
│   ├── inactivityPeriod — seconds before recovery triggers
│   ├── lastActivity     — timestamp of last on-chain interaction
│   └── subscriptionTier — Free or Premium
│
├── Chainlink Automation
│   ├── checkUpkeep()    — off-chain simulation, finds due wallets
│   └── performUpkeep()  — on-chain execution, transfers ETH to backup
│
└── Treasury
    └── withdrawSubscriptionFees() — subscription revenue only
```

## Repository Structure

```
aeternum-core/
├── src/
│   ├── AeternumVault.sol                    ← Core contract
│   └── interfaces/
│       ├── IAeternumVault.sol               ← Full interface (events, errors, structs, functions)
│       └── AutomationCompatibleInterface.sol ← Inlined Chainlink interface
│
├── test/
│   ├── unit/
│   │   └── AeternumVault.t.sol              ← Unit, fuzz, and invariant tests
│   └── mocks/
│       ├── ReentrantAttacker.sol            ← Reentrancy security test helper
│       └── RejectingReceiver.sol            ← Failed recovery simulation helper
│
├── script/
│   ├── Deploy.s.sol                         ← Deployment script with post-deploy checks
│   └── HelperConfig.s.sol                   ← Network-aware configuration resolver
│
├── lib/                                     ← Foundry dependencies
├── foundry.toml                             ← Foundry configuration
├── .solhint.json                            ← Solhint linting rules
└── .env.example                             ← Environment variable template
```

## Trust Model

| Actor | Can Do | Cannot Do |
|---|---|---|
| **User** | Register, deposit, send, withdrawAll, ping, update config, cancel | Access other users' funds |
| **Treasury** | Withdraw accumulated subscription fees | Touch user vault balances |
| **Chainlink Automation** | Call `performUpkeep` when inactivity conditions are met | Alter configs or redirect funds |
| **Anyone** | Call `checkUpkeep` (read-only, off-chain simulation) | Trigger recovery before period elapses |
| **No one** | Pause recovery, upgrade the contract, or access user funds | — |

## How It Works

**1. Register**

The user calls `register()` with a backup address, inactivity period, and subscription tier. ETH deposited at registration goes directly into their vault.

**2. Use the vault**

The vault behaves like a normal wallet. Users can `deposit()` ETH, `send()` ETH to any address, `withdrawAll()` back to themselves, and update their recovery configuration at any time. Every interaction resets the inactivity timer — proving liveness to the contract.

**3. Stay alive**

If a user wants to prove liveness without moving funds, they call `ping()` — a single cheap storage write that resets the timer.

**4. Recovery triggers**

Chainlink Automation polls `checkUpkeep()` off-chain every ~12 seconds. When a vault's inactivity period has elapsed and its balance is non-zero, the Automation node submits `performUpkeep()` on-chain, transferring the ETH to the backup address.

**5. Failed recovery**

If a backup address cannot receive ETH (e.g. a contract that rejects transfers), the failure is counted. After `MAX_RECOVERY_ATTEMPTS` consecutive failures, the vault is permanently deregistered but the balance remains fully accessible — the user can still `send()` or `withdrawAll()` at any time. Re-registration is blocked until the user resolves the backup address issue.

**6. Cancel anytime**

Users can call `cancelRecovery()` at any time to withdraw their full balance and deregister from monitoring in a single transaction.

## Constants

| Constant | Value | Description |
|---|---|---|
| `MIN_INACTIVITY_PERIOD_FREE` | 365 days | Minimum inactivity period for Free tier |
| `MIN_INACTIVITY_PERIOD_PREMIUM` | 180 days | Minimum inactivity period for Premium tier |
| `MAX_INACTIVITY_PERIOD` | 3650 days | Hard ceiling — 10 years |
| `SUBSCRIPTION_DURATION` | 30 days | Premium subscription window |
| `PREMIUM_MONTHLY_FEE` | 0.002 ETH | Fee required for Premium registration or renewal |
| `MAX_BATCH_SIZE` | 50 | Maximum wallets processed per `performUpkeep` call |
| `MAX_RECOVERY_ATTEMPTS` | 3 | Consecutive failures before vault is abandoned |

## Dependencies

### Required

- **[Foundry](https://book.getfoundry.sh/getting-started/installation)** — Development framework

  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ```

- **[OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)** — ReentrancyGuard

  ```bash
  forge install OpenZeppelin/openzeppelin-contracts --no-commit
  ```

### Optional

- **[Slither](https://github.com/crytic/slither)** — Static analysis

  ```bash
  pip install slither-analyzer --break-system-packages
  ```

- **[Solhint](https://github.com/protofire/solhint)** — Linting

  ```bash
  npm install -g solhint
  ```

- **[lcov](https://github.com/linux-test-project/lcov)** — Coverage reports

  ```bash
  # Ubuntu
  sudo apt install lcov

  # macOS
  brew install lcov
  ```

## Quickstart

### 1. Clone the repository

```bash
git clone https://github.com/Aeternumlabs/aeternum-core.git
cd aeternum-core
```

### 2. Install dependencies

```bash
forge install
```

### 3. Set environment variables

```bash
cp .env.example .env
# Copy this file to .env and fill in values
# NEVER commit .env to version control

# RPC endpoints
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
BASE_MAINNET_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY

# Etherscan verification
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_KEY
```

### 4. Build contracts

```bash
forge build
```

## Development

### Testing

```bash
# Full test suite
forge test -vv

# With gas report
forge test --gas-report

# Specific test
forge test --match-test test_performUpkeep_executesRecovery -vvvv

# Fuzz tests only
forge test --match-test testFuzz -vv

# Invariant tests only
forge test --match-test invariant -vv
```

### Coverage

```bash
# Generate a table showing test coverage percentages
forge coverage 
```

### Static Analysis

```bash
# Slither
slither src/AeternumVault.sol \
  --solc-remaps "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/"

# Solhint
solhint src/AeternumVault.sol
```

### Deployment

```bash
# Dry run — Sepolia
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  -vvvv

# Live deploy + Etherscan verification — Sepolia
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv

# Mainnet — ALWAYS dry run first
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  -vvvv
```

## Chainlink Automation Setup

After deployment:

1. Go to [automation.chain.link](https://automation.chain.link) and connect your wallet
2. Click **Register new upkeep** → select **Custom Logic**
3. Set the target contract to your deployed `AeternumVault` address
4. Set `checkData` to `abi.encode(uint256(0), uint256(50))` for the first upkeep
5. Set gas limit to `5000000`
6. Fund the upkeep with LINK tokens from [faucets.chain.link](https://faucets.chain.link) (Sepolia)

**Scaling to large user counts:**

The contract uses pagination — each upkeep monitors a specific window of registered wallets. For 500,000 wallets, register multiple upkeeps with different `checkData` windows running in parallel:

| Upkeep | checkData | Watches |
|---|---|---|
| Upkeep 1 | `abi.encode(0, 50)` | Wallets 0–49 |
| Upkeep 2 | `abi.encode(50, 50)` | Wallets 50–99 |
| Upkeep 3 | `abi.encode(100, 50)` | Wallets 100–149 |
| ... | ... | ... |

`checkUpkeep` runs off-chain and costs nothing. `performUpkeep` fires on-chain only when a wallet is actually due, deducting LINK from the upkeep balance.

## Security

### Design Principles

- **Checks-Effects-Interactions (CEI)** enforced on all ETH-transferring paths
- **ReentrancyGuard** applied as a secondary defence layer on all state-changing functions
- **No admin backdoors** — the treasury address can only withdraw subscription fees, never user balances
- **Stale `performData` safety** — `_executeRecovery` re-validates every wallet before acting; stale or already-recovered entries are silently skipped
- **O(1) registry removal** — swap-and-pop with 1-indexed mappings prevents array corruption during batch removals
- **Failed recovery handling** — after `MAX_RECOVERY_ATTEMPTS` consecutive failures, the vault is abandoned and balance remains self-claimable; the infinite retry loop is broken
- **Direct ETH transfer rejection** — `receive()` explicitly reverts, preventing accidental ETH loss

### Known Considerations

- `block.timestamp` is used for inactivity comparisons. Validator manipulation is bounded to ~12 seconds — negligible for inactivity periods measured in days and months.
- External ETH transfers inside a loop in `performUpkeep` are acknowledged (Slither: calls-loop). Mitigated by `nonReentrant`, CEI pattern, re-validation per iteration, and `MAX_BATCH_SIZE` cap.

### Audit Status

> Pending — targeting audit engagement prior to mainnet deployment.

### Bug Bounty

> Details to be announced.

## License 

Aeternum Core is licensed under the MIT License.
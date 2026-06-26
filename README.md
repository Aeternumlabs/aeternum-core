# Aeternum Core

[![Lint](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/lint.yml/badge.svg)](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/lint.yml) 
[![Tests](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/test.yml/badge.svg)](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/test.yml)
[![Slither](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/slither.yml/badge.svg)](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/slither.yml)
[![License: BUSL 1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](https://github.com/Aeternumlabs/aeternum-core/blob/main/LICENSE.md)

A non-custodial, automated inheritance protocol for Ethereum assets.

Aeternum Core lets users store ETH in a self-sovereign vault, send and receive funds like a normal wallet, and configure a backup address with an inactivity timer. If the user goes silent beyond their chosen period — lost keys, death, incapacitation — the protocol automatically transfers their ETH to the backup address. No custodians. No admin backdoors. Just code.

## Table of Contents

- [Documentation](https://www.aeternumvault.xyz/docs/)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Trust Model](#trust-model)
- [How It Works](#how-it-works)
- [Immutable Variables](#immutable-variables)
- [Dependencies](#dependencies)
- [Quickstart](#quickstart)
- [Development](#development)
- [Post-Deployment](#post-deployment)
- [Security](#security)
- [Audit](#audit)
- [License](#license)

## Architecture

Aeternum Core is a single-contract architecture. Each registered wallet has its own isolated vault within the contract — balances are tracked individually, never pooled. Recovery is triggered via a permissionless `triggerRecovery(wallet)` function. The Aeternum keeper bot monitors all registered vaults via the Ponder indexer and submits recovery transactions automatically when inactivity conditions are met. Because the entry point is permissionless, any external actor can also submit recovery — the contract enforces all safety conditions independently of who calls it.

```
AeternumVault
├── User Vault (per address)
│   ├── balance          — ETH held in escrow
│   ├── backupAddress    — recovery destination
│   ├── inactivityPeriod — seconds before recovery triggers
│   └── lastActivity     — timestamp of last on-chain interaction
│
└── Keeper Interface (permissionless)
    ├── triggerRecovery(wallet)         — permissionless recovery entry point
    └── getTriggerableVaultsBatch(start, size)   — batch view for efficient keeper scanning
```

## Repository Structure

```
aeternum-core/
├── src/
│   ├── AeternumVault.sol                          ← Core contract
│   └── interfaces/
│       └── IAeternumVault.sol                     ← Full interface (events, errors, structs, functions)
│
├── test/
│   ├── unit/
│   │   └── AeternumVault.t.sol                    ← Unit, fuzz, and invariant tests
│   ├── invariant/
│   │   └── AeternumVaultEchidna.sol               ← Echidna property-based fuzzing suite
│   └── mocks/
│       ├── ReentrantAttacker.sol                  ← Reentrancy security test helper
│       ├── RejectingReceiver.sol                  ← Failed recovery simulation helper
│       └── RejectingCallerMock.sol                ← Transfer failure simulation (withdrawAll/cancel)
│
├── script/
│   ├── Deploy.s.sol                               ← Deployment script with post-deploy checks
│   └── HelperConfig.s.sol                         ← Network-aware configuration resolver
│
├── audits/
│   └── 2026-05-04_Aeternum-core_audit.pdf         ← Security audit report
│
├── lib/
│   ├── forge-std                                  ← Foundry standard library
│   └── openzeppelin-contracts                     ← OpenZeppelin contracts
│
├── echidna.config.yml                             ← Echidna fuzzer configuration
├── foundry.lock                                   ← Foundry dependency lockfile
├── foundry.toml                                   ← Foundry configuration
├── .solhint.json                                  ← Solhint linting rules
├── .env.example                                   ← Environment variable template
├── README.md                                      ← Project overview and documentation
├── CONTRIBUTING.md                                ← Contribution guidelines
├── LICENSE.md                                     ← License (BUSL 1.1)
└── SECURITY.md                                    ← Security policy and vulnerability disclosure
```

## Trust Model

| Actor | Can Do | Cannot Do |
|---|---|---|
| **User** | Register, deposit, send, withdrawAll, ping, update config, cancel | Access other users' funds |
| **Aeternum keeper bot** | Call `triggerRecovery(wallet)` when inactivity conditions are met | Alter configs, redirect funds, or trigger early recovery |
| **Anyone** | Call `triggerRecovery(wallet)` (permissionless) and `getTriggerableVaultsBatch` (view) | Force recovery before the inactivity period elapses |
| **No one** | — | Pause recovery, upgrade the contract, or access user funds |

## How It Works

**1. Register**

The user calls `register()` with a backup address and inactivity period. ETH deposited at registration goes directly into their vault.

**2. Use the vault**

The vault behaves like a normal wallet. Users can `deposit()` ETH, `send()` ETH to any address, `withdrawAll()` back to themselves, and update their recovery configuration at any time. Every interaction resets the inactivity timer — proving liveness to the contract.

**3. Stay active**

If a user wants to prove liveness without moving funds, they call `ping()` — a single cheap storage write that resets the timer.

**4. Recovery triggers**

The Aeternum keeper bot continuously monitors all registered vaults via the Ponder indexer. When a vault's inactivity period has elapsed and its balance is non-zero, the bot calls `triggerRecovery(wallet)`, transferring the escrowed ETH to the registered backup address. The function is permissionless — any external actor, including the beneficiary, can also submit the call. The contract validates all conditions independently of the caller.

**5. Failed recovery**

If a backup address cannot receive ETH (e.g. a contract that rejects transfers), the failure is counted. After `MAX_RECOVERY_ATTEMPTS` consecutive failures, the vault is deregistered and the balance remains fully accessible — the user can still `send()` or `withdrawAll()` at any time, and can re-register with a new backup address.

**6. Cancel anytime**

Users can call `cancelRecovery()` at any time to withdraw their full balance and deregister from monitoring in a single transaction.

## Immutable Variables

| Immutable Variable | Value | Description |
|---|---|---|
| `MIN_INACTIVITY_PERIOD` | 180 days (5 minutes for testnet) | Minimum inactivity period users are allowed to configure |
| `MAX_INACTIVITY_PERIOD` | 3650 days | Maximum allowed inactivity period to prevent permanent fund lockup |
| `MAX_RECOVERY_ATTEMPTS` | 3 | Consecutive failed recovery attempts before a vault is permanently abandoned |

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

- **[Echidna](https://github.com/crytic/echidna)** — Property-based fuzz testing

  ```bash
  docker pull ghcr.io/crytic/echidna/echidna
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
forge test --match-test test_triggerRecovery_executesRecovery -vvvv

# Fuzz tests only
forge test --match-test testFuzz -vv

# Invariant tests only
forge test --match-test invariant -vv
```

### Coverage

```bash
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

### Property-Based Fuzz Testing

```bash
# Create Echidna alias
alias echidna='docker run --rm -v $(pwd):/src -w /src ghcr.io/crytic/echidna/echidna echidna'
source ~/.bashrc

# Run property-based fuzzing
echidna test/invariant/AeternumVaultEchidna.sol \
  --contract AeternumVaultEchidna \
  --config echidna.config.yml
```

### Deployment

```bash
# Import your private key into Foundry's local keystore
cast wallet import private-key --interactive

# Dry run — Sepolia
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  -vvvv

# Live deploy + Etherscan verification — Sepolia
forge script script/Deploy.s.sol \
  --account private-key \
  --rpc-url $SEPOLIA_RPC_URL \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --broadcast \
  --verify \
  -vvvv

# Dry run — Mainnet (always run before broadcasting)
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  -vvvv

# Live deploy + Etherscan verification — Mainnet
forge script script/Deploy.s.sol \
  --account private-key \
  --rpc-url $MAINNET_RPC_URL \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --broadcast \
  --verify \
  -vvvv
```

## Post-Deployment

After deploying the contract:

1. Copy the deployed contract address into `.env` as `CONTRACT_ADDRESS`.
2. Set `NEXT_PUBLIC_SEPOLIA_CONTRACT_ADDRESS` in the frontend `.env`.
3. Update the Ponder indexer start block and contract address in `ponder.config.ts`.
4. Start the keeper bot, pointing it at the deployed contract address and the running Ponder instance. The bot begins monitoring immediately — no on-chain registration required.
5. Verify end-to-end: register a test vault with the minimum inactivity period, wait for expiry, and confirm the keeper bot submits `triggerRecovery` and the ETH reaches the backup address.

## Security

### Design Principles

- **Checks-Effects-Interactions (CEI)** enforced on all ETH-transferring paths
- **ReentrancyGuard** applied as a secondary defence layer on all state-changing functions
- **No admin backdoors** — the contract contains no owner or privileged roles capable of pausing recovery, redirecting funds, or accessing user balances
- **Permissionless entry point safety** — `triggerRecovery(wallet)` delegates entirely to `_executeRecovery`, which re-validates all conditions from storage before acting. The caller supplies only a wallet address — they cannot redirect funds, force early recovery, or cause double-spend regardless of who they are
- **O(1) registry removal** — swap-and-pop with 1-indexed mappings prevents array corruption during concurrent recovery and cancellation
- **Failed recovery handling** — after `MAX_RECOVERY_ATTEMPTS` consecutive failures, the vault is permanently abandoned and the balance remains self-claimable via `withdrawAll()` or `send()`
- **Direct ETH transfer rejection** — `receive()` explicitly reverts, preventing accidental ETH loss

### Known Considerations

- `block.timestamp` is used for inactivity comparisons. Validator manipulation is bounded to ~12 seconds — negligible for inactivity periods measured in days and months.
- The external ETH transfer in `_executeRecovery` is acknowledged (Slither: reentrancy-eth). Exploitation is prevented by `nonReentrant` on `triggerRecovery`, balance zeroing before the call (CEI), and permanent abandonment after `MAX_RECOVERY_ATTEMPTS` consecutive failures — eliminating the retry loop entirely.

## Audit

### Internal Audit Report

- [Aeternum-core audit report](audits/2026-06-03_Aeternum_Smart_Contract_Audit_Report.pdf)

### External Audit Report

> Pending — targeting external audit engagement prior to mainnet deployment.

### Bug Bounty

> Details to be announced soon.

## License

AeternumVault V1 is source-available and licensed under the Business Source License 1.1 (BUSL-1.1). The protocol will automatically transition to GNU General Public License, version 3.0 or later, the earlier of (a) four years from the date of the first production deployment of the Licensed Work on the Ethereum Mainnet, or (b) January 1, 2031.

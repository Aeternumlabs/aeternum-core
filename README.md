# Aeternum Core

[![Lint](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/lint.yml/badge.svg)](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/lint.yml) 
[![Tests](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/test.yml/badge.svg)](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/test.yml)
[![Slither](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/slither.yml/badge.svg)](https://github.com/Aeternumlabs/aeternum-core/actions/workflows/slither.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

A trustless smart wallet vault with built-in automated ETH recovery.

Aeternum Core lets users store ETH in a self-sovereign vault, send and receive funds like a normal wallet, and configure a backup address with an inactivity timer. If the user goes silent beyond their chosen period — lost keys, death, incapacitation — Chainlink Automation transfers their ETH to the backup address automatically. No custodians. No admin backdoors. Just code.

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
- [Chainlink Automation Setup](#chainlink-automation-setup)
- [Security](#security)
- [Audit](#audit)
- [License](#license)

## Architecture

Aeternum Core is a single-contract architecture. Each registered wallet has its own isolated vault within the contract — balances are tracked individually, never pooled. Chainlink Automation nodes monitor all registered vaults off-chain and execute recovery on-chain only when inactivity conditions are met.

```
AeternumVault
├── User Vault (per address)
│   ├── balance          — ETH held in escrow
│   ├── backupAddress    — recovery destination
│   ├── inactivityPeriod — seconds before recovery triggers
│   └── lastActivity     — timestamp of last on-chain interaction
│
└── Chainlink Automation
    ├── checkUpkeep()    — off-chain simulation, finds due wallets
    └── performUpkeep()  — on-chain execution, transfers ETH to backup
```

## Repository Structure

```
aeternum-core/
├── src/
│   ├── AeternumVault.sol                          ← Core contract
│   └── interfaces/
│       ├── IAeternumVault.sol                     ← Full interface (events, errors, structs, functions)
│       └── AutomationCompatibleInterface.sol      ← Inlined Chainlink interface
│
├── test/
│   ├── unit/
│   │   └── AeternumVault.t.sol                    ← Unit, fuzz, and invariant tests
│   ├── echidna/
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
├── docs/
│   └── Aeternum-core_technical_doc.pdf            ← Protocol technical documentation
│
├── lib/
│   ├── forge-std                                  ← Foundry standard library
│   └── openzeppelin-contracts                     ← OpenZeppelin contracts
│
├── echidna.config.yml                             ← Echidna fuzzer configuration
├── foundry.lock                                   ← Foundry dependency lockfile
├── foundry.toml                                   ← Foundry configuration
├── .solhint.json                                  ← Solhint linting rules
└── .env.example                                   ← Environment variable template
```

## Trust Model

| Actor | Can Do | Cannot Do |
|---|---|---|
| **User** | Register, deposit, send, withdrawAll, ping, update config, cancel | Access other users' funds |
| **Chainlink Automation** | Call `performUpkeep` via the registered forwarder when inactivity conditions are met | Alter configs or redirect funds |
| **Anyone** | Call `checkUpkeep` (read-only, off-chain simulation) | Call `performUpkeep` once forwarder is set |
| **No one** | — | Pause recovery, upgrade the contract, or access user funds |

## How It Works

**1. Register**

The user calls `register()` with a backup address and inactivity period. ETH deposited at registration goes directly into their vault.

**2. Use the vault**

The vault behaves like a normal wallet. Users can `deposit()` ETH, `send()` ETH to any address, `withdrawAll()` back to themselves, and update their recovery configuration at any time. Every interaction resets the inactivity timer — proving liveness to the contract.

**3. Stay alive**

If a user wants to prove liveness without moving funds, they call `ping()` — a single cheap storage write that resets the timer.

**4. Recovery triggers**

Chainlink Automation polls `checkUpkeep()` off-chain every ~12 seconds. When a vault's 
inactivity period has elapsed and its balance is non-zero, the Automation node submits 
`performUpkeep()` on-chain via the registered forwarder contract, transferring the ETH 
to the backup address. 

**5. Failed recovery**

If a backup address cannot receive ETH (e.g. a contract that rejects transfers), the failure is counted. After `MAX_RECOVERY_ATTEMPTS` consecutive failures, the vault is deregistered but the balance remains fully accessible — the user can still `send()` or `withdrawAll()` at any time, and can re-register but with a new backup address.

**6. Cancel anytime**

Users can call `cancelRecovery()` at any time to withdraw their full balance and deregister from monitoring in a single transaction.

## Immutable variables

| Immutable variable | Value | Description |
|---|---|---|
| `MIN_INACTIVITY_PERIOD` | 180 days (5 minutes for testnet) | Minimum inactivity period users are allowed to configure |
| `MAX_INACTIVITY_PERIOD` | 3650 days | Maximum allowed inactivity period to prevent permanent fund lockup |
| `MAX_CHECK_UPKEEP_SIZE` | 5,000 | Maximum wallets scanned per `checkUpkeep` call (off-chain simulation, no gas constraint) |
| `MAX_PERFORM_UPKEEP_SIZE` | 50 | Maximum wallets recovered per `performUpkeep` call (on-chain execution, gas-bound) |
| `MAX_RECOVERY_ATTEMPTS` | 3 | Consecutive failed recovery attempts before a vault is permanently abandoned |
| `CURSOR_ADVANCE_INTERVAL` | 1 hour | Minimum time between idle cursor advances when no wallets are due |

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

- **[Echidna](https://github.com/crytic/echidna)** — Property-based fuzz test

  ```bash
  # install from docker
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
# Copy .env.example file to .env and fill in values
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

### Property-Based Fuzz Test

```bash
# create Echidna alias
alias echidna='docker run --rm -v $(pwd):/src -w /src ghcr.io/crytic/echidna/echidna echidna'
source ~/.bashrc

# Fuzz
echidna test/echidna/AeternumVaultEchidna.sol --contract AeternumVaultEchidna --config echidna.config.yml
```

### Deployment

```bash
# Import your private key into Foundry’s local keystore
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

# Dry run — Mainnet
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

## Chainlink Automation Setup

After deployment:

1. Go to [automation.chain.link](https://automation.chain.link) and connect your wallet
2. Click **Register new upkeep** → select **Custom Logic**
3. Set the target contract to your deployed `AeternumVault` address
4. `checkData` should be empty
5. Set gas limit to `500000`
6. Fund the upkeep with LINK tokens from [faucets.chain.link](https://faucets.chain.link) (Sepolia)
7. After registration, open your upkeep details and copy the **Forwarder** address
8. Call `setForwarder(forwarderAddress)` on your deployed contract — this permanently locks
   `performUpkeep` so only Chainlink's forwarder can call it. This can only be set once.

## Security

### Design Principles

- **Checks-Effects-Interactions (CEI)** enforced on all ETH-transferring paths
- **ReentrancyGuard** applied as a secondary defence layer on all state-changing functions
- **No admin backdoors** — the contract contains no owner or privileged roles capable of pausing recovery, redirecting funds, or accessing user balances
- **Chainlink forwarder gating** — once `setForwarder()` is called post-deployment, 
  `performUpkeep()` rejects all callers except the designated Chainlink Automation 
  forwarder address. The setter is callable exactly once and locks permanently.
- **Stale `performData` safety** — `_executeRecovery` re-validates every wallet before acting; stale or already-recovered entries are silently skipped
- **O(1) registry removal** — swap-and-pop with 1-indexed mappings prevents array corruption during batch removals
- **Failed recovery handling** — after `MAX_RECOVERY_ATTEMPTS` consecutive failures, the vault is abandoned and balance remains self-claimable
- **Direct ETH transfer rejection** — `receive()` explicitly reverts, preventing accidental ETH loss

### Known Considerations

- `block.timestamp` is used for inactivity comparisons. Validator manipulation is bounded to ~12 seconds — negligible for inactivity periods measured in days and months.
- External ETH transfers inside a loop in `performUpkeep` are acknowledged (Slither: calls-loop). Mitigated by `nonReentrant`, CEI pattern, re-validation per iteration, and `MAX_PERFORM_UPKEEP_SIZE`
- `_executeRecovery` restores state after a failed ETH transfer (Slither: reentrancy-eth). 
  Silenced and acknowledged — exploitation is prevented by `nonReentrant` on `performUpkeep`, 
  balance zeroing before the call, and permanent abandonment after 3 consecutive failures.

## Audit

### Internal audit report

- [Aeternum-core audit report](audits/2026-05-04_Aeternum-core_audit.pdf)

### External audit report

> Pending — targeting external audit engagement prior to mainnet deployment.

### Bug Bounty

> Details to be announced.

## License 

Aeternum Core is licensed under the MIT License.
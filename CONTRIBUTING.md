# Contribution Guidelines

Thanks for your interest in contributing to Aeternum Core! This repository is the home of the core Aeternum vault contract and its security-focused test suite. We are building in public and welcome contributions of any size — from issue reports and reviews to tests, documentation, and code improvements.

If you want to get in touch with repository maintainers, the best way is to open an issue on GitHub and we will respond there.

## Types of Contributing

There are many ways to contribute, but here are a few if you want a place to start:

1. **Opening an issue.** Before filing, please check whether the issue already exists. If it does, add details, examples, or reproduction steps to the open issue rather than creating a duplicate.
2. **Resolving an issue.** Fix an issue by adding code changes, test coverage, or documentation updates. Reference the issue in the pull request.
3. **Reviewing open PRs.** Provide feedback on naming, gas optimizations, test coverage, security assumptions, or alternative designs.

## Opening an Issue

When opening an issue, choose the most appropriate type and include clear reproduction steps or a problem statement. If reporting a bug, include a minimal test case or description of the failing behavior. If suggesting an improvement, explain the expected behavior and why it matters.

Not all issues will be resolved immediately, so please follow through with any questions or comments from maintainers.

## Opening a Pull Request

All pull requests should be opened against the `main` branch. Please reference the issue you are fixing or the enhancement you are proposing.

Pull requests may be reviewed by community members, but approval from repository maintainers is required before merging. Maintainers will try to respond as soon as possible, but please be patient.

For larger or more substantial design changes, open an issue first and discuss the change with maintainers before spending extensive development time.

Before opening a pull request, please do the following:

- Check that the code style follows the [standards](#standards).
- Run the tests and verify they pass. The commands are listed in the [tests](#tests) section.
- Document any new functions, structs, or interfaces using NatSpec.
- Add tests. Smaller contributions should include unit tests and fuzz tests where possible. Larger contributions should include integration tests or invariant tests as appropriate.
- Make sure all commits are signed if your GitHub account requires signed commits.

## Standards

All contributions must follow these standards. PRs that do not adhere may be closed until updated.

1. Format Solidity contracts with the default Foundry formatter by running `forge fmt`.
2. Follow the Solidity style guide and existing project conventions. Contract names, function names, and events should be clear and expressive.
3. External-facing contracts should implement interfaces and document public and external functions with NatSpec comments.
4. If you pick up a stale issue or PR from another contributor, it is fine to continue the work; please communicate with the original author and consider adding them as a co-author.
5. Keep pull request histories clean and squash commits where appropriate; merged PRs will typically be squashed into a single commit.

## Tests

Use the following commands to run tests and validate your changes:

- `forge fmt` — format Solidity sources.
- `forge test --isolate` — run all tests in isolation and update snapshots if necessary.
- `forge test --match-path test/unit/AeternumVault.t.sol` — run the contract-specific unit test suite.
- `forge test --match-path test/echidna/AeternumVaultEchidna.sol` — run property-based fuzz tests.

If you add new functionality, include tests for both normal and edge-case behavior.

## Setup

To get started locally:

```bash
git clone https://github.com/Aeternumlabs/aeternum-core.git
cd aeternum-core
forge install
```

Optional tools used by the repository:

- `slither` for static analysis.
- `echidna` for property-based fuzzing.
- `solhint` for additional lint checks.

## Code of Conduct

Above all else, be respectful and constructive. Aggressive or disrespectful language will not be tolerated.

Spammy, off-topic, or unhelpful issues and pull requests may be closed at maintainers' discretion.

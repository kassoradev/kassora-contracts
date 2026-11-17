# Security Policy

## Status

These contracts are **unaudited**. Do not deposit funds you cannot afford to lose.
Audit reports will be published in [`audits/`](./audits) as they are completed.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

- Email: security@kassora.org
- Or use GitHub's private vulnerability reporting: *Security → Report a vulnerability* on this repository.

Include the affected contract and commit, a description of the issue, and a proof of concept if you have one.
We aim to acknowledge reports within 48 hours and to share a remediation plan within 7 days.

## Scope

| In scope | Out of scope |
| --- | --- |
| `src/KassoraVault.sol` | `test/`, `script/`, mocks |
| `src/strategies/*.sol` | Third-party protocols the strategies integrate (Spark, Morpho, …) |
| Deployed addresses in `deployments/` | Front-end, docs, indexer |

## Trust assumptions

- **Owner** (intended: multisig) sets roles, fee and timelock. Fee is hard-capped at 30% of profit in the contract.
- **Curator** chooses strategies and allocations within caps. New strategies and cap increases wait for the timelock.
- **Guardian** can pause deposits, revoke pending changes and force an emergency exit from a strategy.
- Withdrawals are never paused. Liquidity can still be limited by what the underlying strategies can release.

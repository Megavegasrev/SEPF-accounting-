# SEPF Treasury

Internal treasury-management web application for **Société d'Exploitation des
Produits Forestiers (SEPF)** — Gabon, currency FCFA (XAF). Two-tier treasury
(small / large) with funds in transit, a role-based approval workflow, an
immutable financial ledger and a full audit trail.

> **This repository contains the Foundation and Requests milestones (drafts).**
> Milestone 2 — authentication, roles & permissions, treasury accounts and the
> immutable ledger. Milestone 3 — the request lifecycle, versioning, the
> two-step approval workflow, full-only payments and the Cashier advance path.
> Both are database schema + design drafts for review, validated on PostgreSQL
> 16. The frontend/PWA and the remaining modules (controls & transfers,
> salaries, investments, capital, loans, borrowings, reports) follow next.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — stack, layered authorization,
  financial-integrity model, open decisions, milestone mapping.
- [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) — ERD, table catalogue and
  traceability from each §13.1 integrity rule to its enforcement.
- [`docs/REQUESTS_WORKFLOW.md`](docs/REQUESTS_WORKFLOW.md) — request lifecycle
  state machine, approval/payment functions and §6/§17.1 traceability.
- [`docs/CONTROLS_TRANSFERS.md`](docs/CONTROLS_TRANSFERS.md) — accounting control,
  supporting documents, internal receipts and the funds-in-transit transfer rule.
- [`docs/SALARIES.md`](docs/SALARIES.md) — salary profiles, monthly cycles, the
  advance anti-overrun ceiling and outstanding-balance settlement.
- [`docs/INVESTMENTS_CAPITAL.md`](docs/INVESTMENTS_CAPITAL.md) — SEPF investments
  & asset register, and shareholder capital contributions.

## Repository layout

```
db/
  migrations/   ordered DDL — apply in filename order (0001 … 0020)
  seed/         roles & permissions, the five users + three treasuries, demo data
  tests/        acceptance checks (psql): 0001 foundation, 0002 requests,
                0003 controls & transfers, 0004 salaries, 0005 investments & capital
docs/           architecture, data-model & workflow documents
```

## Quick start (local PostgreSQL)

```bash
createdb sepf
# 1. schema, then 2. seed data (roles, the 5 accounts, 3 treasuries, demo income)
for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
# 3. run the acceptance checks (all should pass; "EXPECT FAIL" lines must error)
psql -d sepf -f db/tests/0001_foundation_checks.sql
psql -d sepf -f db/tests/0002_requests_checks.sql
psql -d sepf -f db/tests/0003_controls_transfers_checks.sql
psql -d sepf -f db/tests/0004_salaries_checks.sql
psql -d sepf -f db/tests/0005_investments_capital_checks.sql
```

The seed creates the five roles and a placeholder account for each, with locked
passwords (`!`) and `must_change_password = true`; real credentials are set per
environment at deploy time (see the architecture doc). Demo accounts use the
`.test` domain only — no real data (§15.2).

## Status against the specification

Implemented and validated: derived balances, immutable ledger, idempotent
postings, two-tier (small/large) authorization enforced in the database via
Row-Level Security and `SECURITY DEFINER` functions, income recording and
reversals/adjustments; the full request lifecycle — creation, versioning, the
First-Level Validator → Super Administrator approval workflow, full-only payments
(no partial), insufficient-funds handling, and the Cashier's pre-approval
disbursement (§6.5); accounting control with no financial effect, supporting
documents with hash-based reuse detection, internal receipts, and manual
treasury transfers that conserve the consolidated total via funds in transit
(§10.3); salary profiles, monthly cycles, advances with the anti-overrun ceiling
and outstanding-balance settlement that carries debt forward (§8); SEPF
investments with an asset register and shareholder capital contributions that
increase the large treasury only after the Accountant confirms receipt (§9). See
the architecture doc's *Open decisions* for items that need SEPF's written
confirmation before later milestones (§19.1).

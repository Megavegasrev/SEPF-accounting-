# SEPF Treasury

Internal treasury-management web application for **Société d'Exploitation des
Produits Forestiers (SEPF)** — Gabon, currency FCFA (XAF). Two-tier treasury
(small / large) with funds in transit, a role-based approval workflow, an
immutable financial ledger and a full audit trail.

> **This repository currently contains the Foundation milestone draft** —
> authentication, roles & permissions, treasury accounts and the financial
> ledger (Milestone 2 of the specification). It is a database schema +
> architecture draft for review, validated on PostgreSQL 16. The frontend/PWA
> and the remaining business modules (requests, payments, transfers, salaries,
> investments, capital, loans, borrowings, reports) follow in later milestones.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — stack, layered authorization,
  financial-integrity model, open decisions, milestone mapping.
- [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) — ERD, table catalogue and
  traceability from each §13.1 integrity rule to its enforcement.

## Repository layout

```
db/
  migrations/   ordered DDL — apply 0001 … 0007 in filename order
  seed/         roles & permissions, the five users + three treasuries, demo data
  tests/        foundation acceptance checks (psql)
docs/           architecture & data-model documents
```

## Quick start (local PostgreSQL)

```bash
createdb sepf
# 1. schema, then 2. seed data (roles, the 5 accounts, 3 treasuries, demo income)
for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
# 3. run the acceptance checks (all should pass; "EXPECT FAIL" lines must error)
psql -d sepf -f db/tests/0001_foundation_checks.sql
```

The seed creates the five roles and a placeholder account for each, with locked
passwords (`!`) and `must_change_password = true`; real credentials are set per
environment at deploy time (see the architecture doc). Demo accounts use the
`.test` domain only — no real data (§15.2).

## Status against the specification

Implemented and validated: derived balances, immutable ledger, idempotent
postings, two-tier (small/large) authorization enforced in the database via
Row-Level Security and `SECURITY DEFINER` functions, income recording, and
reversals/adjustments. See the architecture doc's *Open decisions* for items that
need SEPF's written confirmation before later milestones (§19.1).

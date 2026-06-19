# SEPF Treasury — Application Service Layer (Phase 1)

The server-only layer that the UI (and API routes) call. It **wraps the existing
database functions and views** — it never writes the ledger directly and never
re-implements business rules. Stack: Next.js App Router + TypeScript (strict),
postgres.js, Zod, Vitest. Validated on PostgreSQL 16.

## How RLS & SECURITY DEFINER are guaranteed

Every call runs in a transaction that sets the database role and the acting user,
exactly like the SQL test suites:

```ts
withUser(userId, tx => …)  // SET LOCAL ROLE app_user; set app.current_user_id = userId
withService(tx => …)       // SET LOCAL ROLE service_role  (auth/session/bootstrap only)
```

So Postgres enforces RLS and runs the `SECURITY DEFINER` functions; `app_user`
has no direct DML on the ledger. In production the app connects with a
least-privilege login role that is a member of `app_user`/`service_role`
(`db/deploy/00_app_login_role.sql.example`) — never a superuser.

## Layout

```
src/
  db/client.ts     postgres.js client + withUser/withService; numeric -> JS number
  db/errors.ts     PgError (SQLSTATE + message) -> French AppError
  lib/types.ts     types mirroring every table, view and function return
  lib/password.ts  bcrypt hash/verify          lib/session.ts  token + DB sessions
  lib/permissions.ts  permission-code constants (UI gating only)
  lib/schemas/     Zod schemas (French messages) for all inputs
  services/        auth · treasury · requests · controls · transfers · salaries ·
                   investments · capital · loans · borrowings · reports
tests/
  setup/global.ts  builds a throwaway sepf_test DB from db/migrations + db/seed
  services/*.test.ts
```

## Service functions (each wraps the named DB object)

| Domain | Service functions → DB object |
|---|---|
| auth | `login`/`logout`/`getSessionUserId`/`getCurrentUser` → `users`,`sessions`,`role_permissions`,`app_has_permission` |
| treasury | `getBalances`,`getConsolidated` → views; `recordIncome` → `record_income` |
| requests | `createRequest`,`createCorrection`,`recordFirstValidation`,`recordFinalValidation`,`payRequest`,`disburseSmallAdvance`,`listRequests`,`getRequestDetail` |
| controls | `recordAccountingControl`,`addAttachment`,`replaceAttachment`,`confirmInternalReceipt`,`getControlStatus`,`listPaymentsAwaitingControl` |
| transfers | `initiateTransfer`,`confirmTransfer`,`cancelTransfer`,`listTransfers` |
| salaries | `setSalaryProfile`,`openSalaryCycle`,`requestSalaryAdvance`,`paySalaryAdvance`,`paySalaryBalance`,`getCycleSummary`,`listCycleSummaries` |
| investments | `createInvestment`,`payInvestment`,`listAssets` |
| capital | `declareContribution`,`confirmContribution`,`listContributions`,`getShareholderSummary` |
| loans | `createLoanRequest`,`disburseLoan`,`addInstallment`,`recordRepayment`,`listLoans` |
| borrowings | `enterBorrowing`,`confirmReceipt`,`requestRepayment`,`payRepayment`,`listBorrowings` |
| reports | `getTransactionHistory` (filters) → `v_transaction_history`; `recordExport` → `record_export` |

## French errors

`toAppError` maps Postgres errors to French (e.g. `42501` → « Vous n'êtes pas
autorisé à effectuer cette action », insufficient balance → « Solde insuffisant :
aucun paiement n'a été effectué », immutability → « Cette donnée est protégée… »).
Zod schemas carry French validation messages.

## Tests

`npm test` builds `sepf_test` from the shipped migrations/seeds and runs Vitest.
Phase-1 suites (all green): **auth** (login/session/permissions, wrong password →
French), **treasury** (numeric parsing, RLS: Cashier sees only small+transit),
**requests** (approve→approve→pay debits once; exact amount, no partial;
unauthorized role → French; insufficient balance → French; comment required to
refuse). `npm run typecheck` passes under `strict`.

```bash
npm install
npm run typecheck
npm test          # requires a local PostgreSQL with the schema loadable via psql
```

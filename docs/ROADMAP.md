# SEPF Treasury — Implementation Roadmap

Living plan for the full-stack application. The **database backend (Milestones
2–7) is complete and validated**; this roadmap tracks the application layer and
explicitly lists every workflow/screen so nothing is forgotten. Legend: ✅ done ·
🚧 in progress · ◻️ planned.

> Guardrails (apply to every item): UI in French · mobile-first · PWA-ready · no
> public registration · no direct ledger edits · no partial payments · never
> bypass RLS / SECURITY DEFINER · don't duplicate business logic in the UI ·
> translate DB errors to clear French · don't change validated migrations without
> asking.

## Database & service foundation
- ✅ DB backend M2–M7 (ledger, requests, controls/transfers, salaries,
  investments/capital, loans/borrowings/reports) — `db/migrations`, `db/seed`,
  `db/tests` (6 suites green).
- ✅ Database review + complete schema doc (`docs/DATABASE_REVIEW.md`).
- ✅ **Phase 1** — server-only service layer wrapping all functions/views, Zod
  schemas, French error mapper, Vitest (`docs/APP_SERVICE_LAYER.md`).

## Phase 2 — Authentication & protected layout 🚧
- French login page (RHF + Zod) · httpOnly session cookie · middleware cookie
  gate · server-side `requireUser` · role-based redirect · mobile-first shell
  (Accueil / Demandes / Trésorerie / Historique / Plus) · permission-aware FAB ·
  logout. Tests: login, protected routes, role redirect, logout.

## Phase 3 — Role-based dashboards ◻️
Five French dashboards (Super Admin, First-Level Validator, Operations Director,
Cashier, Accountant) with the widgets listed in the brief. **Dashboard widgets to
include** (tracked):
- Treasury balances (petite / grande / fonds en transit / consolidée).
- Cashier/Accountant: **Entrées du jour**, **Entrées du mois**, **Dernières
  entrées** (income widgets — see Phase 4 income workflow).
- Pending validations, disbursed-not-approved expenses, non-validated controls,
  salaries & advances, investments, capital, loans & borrowings, alerts.

## Phase 4 — Core workflows ◻️
Each workflow uses the **service layer only**. Tracked workflows:

1. **Ordinary incoming money / Entrées d'argent** (explicitly tracked)
   - Cashier → small treasury; Accountant → large treasury (role-scoped by
     `income.record.small` / `income.record.large`).
   - Form fields: amount · source/payer · income type · purpose · operation date
     · payment method · external reference · project/activity · supporting
     document (optional).
   - On submit: call `record_income` (approved backend fn) → positive treasury
     movement → balance updates via the derived ledger view → audit log →
     **idempotency key prevents duplicates**.
   - **Income is separate from** capital contributions, borrowings, loan
     repayments and internal transfers — those keep their **own dedicated
     workflows** and must never be recorded as ordinary income.
   - Pages: `/tresorerie/entrees`, `/tresorerie/entrees/nouvelle`,
     `/tresorerie/entrees/[id]`.
   - Dashboard widgets: Entrées du jour · Entrées du mois · Dernières entrées.
   - Tests: cashier small income · accountant large income · unauthorized role
     blocked · duplicate idempotency key → no second movement · ordinary income
     does not touch capital/loan/borrowing/transfer tables.
2. **Expense request** — create · correct · **supporting-document upload** ·
   submit · timeline.
3. **Cashier expense** — incl. « L'argent a-t-il déjà été décaissé ? » →
   pre-validation disbursement (`disburse_small_advance`) vs normal request.
4. **Validation** — First-Level then Super Admin: Valider / Ne pas valider /
   Demander correction (comment required for the last two).
5. **Accountant** — pay approved large expenses; **accounting control queue**
   (Contrôle validé / Contrôle non validé; cause mandatory when not validated).
6. **Transfers** — small↔large with funds-in-transit; initiate/confirm by role.
7. **Salaries** — profile mgmt (Super Admin) · advance request/validation/payment
   · **salary balance payment workflow** · monthly cycle summary.
8. **Investments** — create · validate · pay · asset register.
9. **Capital contributions** — declare · **confirmation page (Accountant)** ·
   separate shareholder histories · no loans/advances in contributions.
10. **Loans & borrowings** — loan request/disbursement/repayment; borrowing
    entry/receipt-confirmation/repayment.

### Cross-cutting workflows explicitly tracked (do not forget)
- ◻️ **Ordinary incoming money workflow** (Phase 4.1, detailed above).
- ◻️ **Supporting document upload** for all relevant operations (requests,
  payments, income, investments, transfers) — storage adapter + signed URLs +
  `add_attachment`/`replace_attachment`; hash-based reuse flagged.
- ◻️ **Accountant control queue** — list of completed payments awaiting control
  (`payment_control_status` where no control yet) + the control action.
- ◻️ **Correction / adjustment workflow without deleting movements** — request
  corrections create new versions; ledger corrections only via `reverse_movement`
  (admin), never deletes; surface clearly in the UI.
- ◻️ **Notifications page** — derived from pending items per role (and the
  `notifications` table if/when populated); mark-as-seen.
- ◻️ **Capital contribution confirmation page** — Accountant confirms/refuses
  receipt (cause mandatory on refusal); treasury increases only on confirmation.
- ◻️ **Salary balance payment workflow** — settle a cycle's outstanding balance
  in full; remains due if treasury insufficient.
- ◻️ **Global transaction detail timeline** — request file timeline (creation →
  decisions → payment → control → receipts) and movement→source drill-down.
- ◻️ **Export audit logging** — every export calls `record_export`; reports for
  all treasuries/expenses/controls/salaries/investments/capital/loans/borrowings/
  transfers.

## Phase 5 — History, audit & reports ◻️
- Global history on `v_transaction_history` with filters (date range · treasury ·
  movement type · amount range · reference · source type · posted by).
- Request detail timeline · payment/control detail · report pages · exports
  (each calling `record_export`).

## Phase 6 — Quality gates & admin ◻️
- ◻️ **Super Administrator user management screen** — create/edit/suspend the five
  accounts (no public registration); reset passwords; assign role (server-side
  via service_role; users.manage).
- ◻️ **Settings screen** — `settings` table (session TTL, advance ceiling, …),
  edited by `settings.manage`.
- ◻️ Lint · type-check · unit + integration tests · production build.
- ◻️ Seed/demo accounts for the five roles (bootstrap script).
- ◻️ **Manual user acceptance test checklist for the five roles** —
  `docs/USER_ACCEPTANCE_TESTS.md` (per-role end-to-end scenarios).
- ◻️ README: installation · env vars · DB setup · test commands · deployment.
- ◻️ Playwright end-to-end smoke tests (full browser) for the critical journeys.

## Open product decisions (carried from the spec review, need SEPF sign-off)
- §4.2 permission-matrix legend & reversal authority · Cashier advance ceiling ·
  approver delegation/deputy · MFA on sensitive actions · transfer cancel
  safeguard · disputed-receipt resolution · treasury routing threshold.

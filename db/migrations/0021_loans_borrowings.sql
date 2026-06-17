-- =============================================================================
-- SEPF Treasury — Milestone 7 (Loans, borrowings and reports)
-- Migration 0021: loans_granted, loan_repayments, company_borrowings,
--                 borrowing_installments + summary views
-- -----------------------------------------------------------------------------
-- Spec references:
--   §10.1 loans granted by SEPF: any user requests; dual approval; the
--         Accountant disburses the full amount from the large treasury; the
--         payment creates a RECEIVABLE (not an ordinary expense); a schedule of
--         several full instalments; repayments increase treasury and reduce the
--         receivable
--   §10.2 borrowings obtained by SEPF: entered administratively (Super Admin /
--         First-Level Validator / Accountant); the Accountant confirms receipt
--         before the large treasury is credited; creates a LIABILITY; repayments
--         require a request + dual approval + full payment; each instalment
--         separates principal, interest and charges
-- Writes happen only through the SECURITY DEFINER functions in 0022; app_user
-- holds SELECT only (the ledger movements remain immutable as ever).
-- =============================================================================

alter table requests drop constraint requests_request_type_check;
alter table requests add constraint requests_request_type_check
    check (request_type in ('expense','salary_advance','investment',
                            'loan','borrowing_repayment'));

-- -----------------------------------------------------------------------------
-- loans_granted — a loan SEPF makes (§10.1), linked 1:1 to its request. The
-- receivable outstanding is derived (principal - repayments received).
-- -----------------------------------------------------------------------------
create table loans_granted (
    id                      uuid primary key default gen_random_uuid(),
    request_id              uuid not null unique references requests(id),
    borrower_name           text not null,
    principal               numeric(18,0) not null check (principal > 0),
    status                  text not null default 'pending'
                                check (status in ('pending','disbursed')),
    disbursement_movement_id uuid references treasury_movements(id),
    disbursed_by            uuid references users(id),
    disbursed_at            timestamptz,
    created_by              uuid not null references users(id),
    created_at              timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- loan_repayments — scheduled instalments, each received in full (§10.1).
-- A received repayment increases the large treasury and reduces the receivable.
-- -----------------------------------------------------------------------------
create table loan_repayments (
    id              uuid primary key default gen_random_uuid(),
    loan_id         uuid not null references loans_granted(id),
    amount          numeric(18,0) not null check (amount > 0),
    due_date        date,
    status          text not null default 'scheduled'
                        check (status in ('scheduled','received')),
    movement_id     uuid references treasury_movements(id),
    idempotency_key text unique,
    received_by     uuid references users(id),
    received_at     timestamptz,
    created_at      timestamptz not null default now()
);

create index idx_loan_repayments_loan on loan_repayments(loan_id);

-- -----------------------------------------------------------------------------
-- company_borrowings — money SEPF borrows (§10.2). Entered administratively;
-- credited only on the Accountant's confirmation. Liability outstanding is
-- derived (principal - principal repaid).
-- -----------------------------------------------------------------------------
create sequence seq_borrowing_reference;
create or replace function next_borrowing_reference()
returns text language sql as $$
    select 'BOR-' || to_char(now(),'YYYY') || '-'
                  || lpad(nextval('seq_borrowing_reference')::text, 6, '0');
$$;

create table company_borrowings (
    id                  uuid primary key default gen_random_uuid(),
    reference           text not null unique default next_borrowing_reference(),
    lender_name         text not null,
    principal           numeric(18,0) not null check (principal > 0),
    status              text not null default 'awaiting_receipt'
                            check (status in ('awaiting_receipt','received','not_received')),
    entered_by          uuid not null references users(id),
    entered_at          timestamptz not null default now(),
    confirmed_by        uuid references users(id),
    confirmed_at        timestamptz,
    not_received_cause  text,
    receipt_movement_id uuid references treasury_movements(id),
    confirm_idempotency_key text unique,
    constraint chk_borrowing_received_movement
        check (status <> 'received' or receipt_movement_id is not null),
    constraint chk_borrowing_not_received_cause
        check (status <> 'not_received'
               or (not_received_cause is not null and btrim(not_received_cause) <> ''))
);

-- -----------------------------------------------------------------------------
-- borrowing_installments — a repayment of a borrowing (§10.2), linked 1:1 to its
-- request (dual approval). Each instalment separates principal/interest/charges.
-- -----------------------------------------------------------------------------
create table borrowing_installments (
    id                 uuid primary key default gen_random_uuid(),
    borrowing_id       uuid not null references company_borrowings(id),
    request_id         uuid not null unique references requests(id),
    principal_part     numeric(18,0) not null default 0 check (principal_part >= 0),
    interest_part      numeric(18,0) not null default 0 check (interest_part >= 0),
    charges_part       numeric(18,0) not null default 0 check (charges_part >= 0),
    status             text not null default 'pending'
                           check (status in ('pending','paid')),
    payment_movement_id uuid references treasury_movements(id),
    paid_by            uuid references users(id),
    paid_at            timestamptz,
    created_at         timestamptz not null default now(),
    constraint chk_installment_positive
        check (principal_part + interest_part + charges_part > 0)
);

create index idx_borrowing_installments_borrowing on borrowing_installments(borrowing_id);

-- -----------------------------------------------------------------------------
-- Summary views — receivables and liabilities (§10, §11.3).
-- -----------------------------------------------------------------------------
create view loan_summary
with (security_invoker = true) as
    select l.id as loan_id,
           l.request_id,
           l.borrower_name,
           l.principal,
           l.status,
           coalesce(sum(r.amount) filter (where r.status = 'received'), 0) as repaid,
           l.principal
               - coalesce(sum(r.amount) filter (where r.status = 'received'), 0)
               as outstanding_receivable
    from loans_granted l
    left join loan_repayments r on r.loan_id = l.id
    group by l.id;

create view borrowing_summary
with (security_invoker = true) as
    select b.id as borrowing_id,
           b.reference,
           b.lender_name,
           b.principal,
           b.status,
           coalesce(sum(i.principal_part) filter (where i.status = 'paid'), 0) as principal_repaid,
           coalesce(sum(i.interest_part)  filter (where i.status = 'paid'), 0) as interest_paid,
           coalesce(sum(i.charges_part)   filter (where i.status = 'paid'), 0) as charges_paid,
           b.principal
               - coalesce(sum(i.principal_part) filter (where i.status = 'paid'), 0)
               as outstanding_liability
    from company_borrowings b
    left join borrowing_installments i on i.borrowing_id = b.id
    group by b.id;

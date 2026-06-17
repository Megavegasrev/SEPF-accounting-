-- =============================================================================
-- SEPF Treasury — Milestone 5 (Salaries and advances)
-- Migration 0015: Salary profiles, cycles, advance requests, balance payments
-- -----------------------------------------------------------------------------
-- Spec references:
--   §8.1  per-user salary configuration (independent of the app role); ceiling
--         <= monthly salary; effective-dated, change history, no retroactive
--         effect (§13.1 rule 6)
--   §8.2  advance: available = ceiling - paid - approved-but-unpaid; full
--         payment only; cumulative <= ceiling; transactional re-check at payment
--   §8.3  outstanding balance = monthly salary - advances actually paid; paid in
--         full from the large treasury; unpaid amount remains due; a new month
--         is a new cycle and never deletes prior debt; totals derive from payments
-- A salary advance reuses the generic request/approval workflow (a request of
-- type 'salary_advance' linked here), honouring §13.1 rule 11.
-- =============================================================================

-- Allow salary-advance requests to flow through the generic request workflow.
alter table requests drop constraint requests_request_type_check;
alter table requests add constraint requests_request_type_check
    check (request_type in ('expense','salary_advance'));

-- -----------------------------------------------------------------------------
-- salary_profiles — append-only, effective-dated configuration per user (§8.1).
-- A change is a new row; existing cycles keep the value snapshotted when created
-- (no retroactive effect). Ceiling is bounded by the salary (§13.1 rule 6).
-- -----------------------------------------------------------------------------
create table salary_profiles (
    id                      uuid primary key default gen_random_uuid(),
    user_id                 uuid not null references users(id),
    salary_eligible         boolean not null default true,
    monthly_salary          numeric(18,0) not null check (monthly_salary >= 0),
    can_request_advance     boolean not null default false,
    monthly_advance_ceiling numeric(18,0) not null default 0,
    effective_date          date not null,
    is_active               boolean not null default true,
    note                    text,
    created_by              uuid not null references users(id),
    created_at              timestamptz not null default now(),
    constraint chk_ceiling_within_salary
        check (monthly_advance_ceiling >= 0
               and monthly_advance_ceiling <= monthly_salary)
);

create index idx_salary_profiles_user on salary_profiles(user_id, effective_date desc);

create trigger trg_salary_profiles_immutable
    before update or delete on salary_profiles
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- salary_cycles — one monthly cycle per user, snapshotting the salary rules in
-- force at creation (§8.1 no retroactive effect, §8.3 a new month = new cycle).
-- -----------------------------------------------------------------------------
create table salary_cycles (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references users(id),
    period              date not null,             -- first day of the month
    monthly_salary      numeric(18,0) not null,     -- snapshot
    advance_ceiling     numeric(18,0) not null,     -- snapshot
    can_request_advance boolean not null,           -- snapshot
    created_at          timestamptz not null default now(),
    constraint uq_cycle unique (user_id, period),
    constraint chk_period_first_of_month check (period = date_trunc('month', period)::date)
);

create index idx_cycles_user on salary_cycles(user_id, period desc);

create trigger trg_salary_cycles_immutable
    before update or delete on salary_cycles
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- salary_advance_requests — links a generic request (the approval workflow) to
-- the salary cycle it draws on (§8.2). Amount mirrors the request version.
-- -----------------------------------------------------------------------------
create table salary_advance_requests (
    id         uuid primary key default gen_random_uuid(),
    request_id uuid not null unique references requests(id),
    cycle_id   uuid not null references salary_cycles(id),
    user_id    uuid not null references users(id),
    amount     numeric(18,0) not null check (amount > 0),
    created_at timestamptz not null default now()
);

create index idx_adv_requests_cycle on salary_advance_requests(cycle_id);
create index idx_adv_requests_user on salary_advance_requests(user_id);

create trigger trg_adv_requests_immutable
    before update or delete on salary_advance_requests
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- salary_balance_payments — settlement of a cycle's outstanding balance (§8.3),
-- paid in full from the large treasury. Append-only; totals derive from here.
-- -----------------------------------------------------------------------------
create table salary_balance_payments (
    id              uuid primary key default gen_random_uuid(),
    cycle_id        uuid not null references salary_cycles(id),
    amount          numeric(18,0) not null check (amount > 0),
    movement_id     uuid not null references treasury_movements(id),
    idempotency_key text not null unique,
    paid_by         uuid not null references users(id),
    paid_at         timestamptz not null default now()
);

create index idx_balance_payments_cycle on salary_balance_payments(cycle_id);

create trigger trg_balance_payments_immutable
    before update or delete on salary_balance_payments
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- Derivations (§8.2/§8.3) — totals computed from payments, never stored editable.
-- SECURITY INVOKER (default): when called inside the SECURITY DEFINER functions
-- they run with the definer's full access; in views they honour the caller's RLS.
-- -----------------------------------------------------------------------------
create or replace function salary_advances_paid(p_cycle uuid)
returns numeric language sql stable as $$
    select coalesce(sum(p.amount), 0)
    from salary_advance_requests sar
    join payments p on p.request_id = sar.request_id
    where sar.cycle_id = p_cycle and p.status = 'completed';
$$;

create or replace function salary_advances_approved_unpaid(p_cycle uuid)
returns numeric language sql stable as $$
    select coalesce(sum(v.amount), 0)
    from salary_advance_requests sar
    join request_versions v on v.request_id = sar.request_id and v.status = 'approved'
    where sar.cycle_id = p_cycle
      and not exists (select 1 from payments p where p.request_id = sar.request_id);
$$;

create or replace function salary_balance_paid(p_cycle uuid)
returns numeric language sql stable as $$
    select coalesce(sum(amount), 0) from salary_balance_payments where cycle_id = p_cycle;
$$;

-- Per-cycle summary used by dashboards and by the anti-overrun checks.
create view salary_cycle_summary
with (security_invoker = true) as
    select c.id as cycle_id,
           c.user_id,
           c.period,
           c.monthly_salary,
           c.advance_ceiling,
           salary_advances_paid(c.id)            as advances_paid,
           salary_advances_approved_unpaid(c.id) as advances_approved_unpaid,
           c.advance_ceiling
               - salary_advances_paid(c.id)
               - salary_advances_approved_unpaid(c.id) as advance_available,
           salary_balance_paid(c.id)             as balance_paid,
           c.monthly_salary
               - salary_advances_paid(c.id)
               - salary_balance_paid(c.id)       as outstanding_balance
    from salary_cycles c;

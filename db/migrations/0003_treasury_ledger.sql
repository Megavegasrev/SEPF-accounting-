-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Migration 0003: Treasury accounts, the immutable financial ledger, balances
-- -----------------------------------------------------------------------------
-- This is the heart of the system. Spec references:
--   §5.1/§5.2/§5.3  small treasury, large treasury, funds in transit
--   §5.4            immutable financial ledger; balances derived, not stored
--   §13.1           amounts as integers/numeric(18,0); idempotency key;
--                   financial movements immutable
-- =============================================================================

-- -----------------------------------------------------------------------------
-- treasury_accounts — exactly one small, one large and one funds-in-transit
-- account. Consolidated total = small + large + transit (§5.3).
-- -----------------------------------------------------------------------------
create table treasury_accounts (
    id                  uuid primary key default gen_random_uuid(),
    account_type        text not null
                            check (account_type in ('small_treasury',
                                                    'large_treasury',
                                                    'funds_in_transit')),
    code                text not null unique,           -- SMALL / LARGE / TRANSIT
    name                text not null,
    -- Opening balance term of the §5.1 formula. Set once at go-live.
    opening_balance     numeric(18,0) not null default 0,
    currency            text not null default 'XAF'     -- FCFA / Central-African CFA
                            check (currency = 'XAF'),
    responsible_user_id uuid references users(id),       -- Cashier / Accountant
    is_active           boolean not null default true,
    created_at          timestamptz not null default now(),
    -- Enforce a single account per type (one small, one large, one transit).
    constraint uq_account_type unique (account_type)
);

comment on table treasury_accounts is
    'One row per treasury (small, large, transit). Balances are NOT stored here '
    'beyond the immutable opening balance — see treasury_balances view (§5.4).';

-- -----------------------------------------------------------------------------
-- Human-readable, gap-tolerant unique reference for every movement (§2 "unique
-- reference"). Format: MOV-YYYY-000123. Uniqueness is guaranteed by the
-- sequence regardless of the year prefix.
-- -----------------------------------------------------------------------------
create sequence seq_movement_reference;

create or replace function next_movement_reference()
returns text
language sql
as $$
    select 'MOV-' || to_char(now(), 'YYYY') || '-'
                  || lpad(nextval('seq_movement_reference')::text, 6, '0');
$$;

-- -----------------------------------------------------------------------------
-- treasury_movements — THE immutable ledger. Every balance is derived from it.
--   * amount is signed: positive = inflow, negative = outflow (§5.4).
--   * idempotency_key makes every posting safe to retry and blocks duplicate
--     financial movements (§13.1).
--   * a reversal carries the opposite sign and links to the original; this is
--     the only sanctioned way to correct a posted movement (§5.4).
--   * source_type/source_id loosely link a movement to its business origin
--     (income entry, payment, transfer …) without a hard FK, so the generic
--     ledger does not need to know every future object.
-- numeric(18,0) — never floating point (§13.1).
-- -----------------------------------------------------------------------------
create table treasury_movements (
    id                   uuid primary key default gen_random_uuid(),
    account_id           uuid not null references treasury_accounts(id),
    amount               numeric(18,0) not null check (amount <> 0),
    movement_type        text not null check (movement_type in (
                             'income', 'expense',
                             'transfer_out', 'transfer_in',
                             'salary', 'salary_advance',
                             'investment',
                             'loan_disbursement', 'loan_repayment',
                             'borrowing_receipt', 'borrowing_repayment',
                             'capital_contribution',
                             'adjustment', 'reversal')),
    reference            text not null unique default next_movement_reference(),
    idempotency_key      text not null unique,
    -- Groups the legs of a single business event (e.g. the two legs of a
    -- transfer) so they can be reconciled and shown together (§10.3).
    movement_group_id    uuid,
    source_type          text,
    source_id            uuid,
    reverses_movement_id uuid references treasury_movements(id),
    memo                 text,
    posted_at            timestamptz not null default now(),
    posted_by            uuid not null references users(id),
    created_at           timestamptz not null default now(),
    -- A reversal must always point at the movement it reverses.
    constraint chk_reversal_link
        check (movement_type <> 'reversal' or reverses_movement_id is not null)
);

comment on table treasury_movements is
    'Append-only financial ledger. Source of truth for all balances (§5.4).';

create index idx_movements_account on treasury_movements(account_id);
create index idx_movements_posted_at on treasury_movements(posted_at);
create index idx_movements_type on treasury_movements(movement_type);
create index idx_movements_source on treasury_movements(source_type, source_id);
create index idx_movements_group on treasury_movements(movement_group_id);

-- A given movement may be reversed at most once.
create unique index uq_movement_single_reversal
    on treasury_movements(reverses_movement_id)
    where reverses_movement_id is not null;

-- Immutability: posted movements can never be updated or deleted (§5.4, §13.1).
create trigger trg_movements_immutable
    before update or delete on treasury_movements
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- treasury_balances — the §13 "treasury_balance_views". Balance is derived,
-- never stored: opening_balance + sum(signed movements). (§5.1/§5.4)
-- security_invoker = true so the querying user's RLS applies (a Cashier must not
-- see large-treasury balances through the view).
-- -----------------------------------------------------------------------------
create view treasury_balances
with (security_invoker = true) as
    select a.id                                            as account_id,
           a.account_type,
           a.code,
           a.name,
           a.currency,
           a.opening_balance
               + coalesce(sum(m.amount), 0)                as balance,
           count(m.id)                                     as movement_count,
           max(m.posted_at)                                as last_movement_at
    from treasury_accounts a
    left join treasury_movements m on m.account_id = a.id
    group by a.id;

-- -----------------------------------------------------------------------------
-- treasury_consolidated — single-row consolidated view (§5.3).
-- total_treasury = small + large + transit, by construction. Also runs with the
-- caller's RLS, so it only consolidates the accounts the caller may see.
-- -----------------------------------------------------------------------------
create view treasury_consolidated
with (security_invoker = true) as
    select
        coalesce(sum(balance) filter (where account_type = 'small_treasury'),   0) as small_treasury,
        coalesce(sum(balance) filter (where account_type = 'large_treasury'),   0) as large_treasury,
        coalesce(sum(balance) filter (where account_type = 'funds_in_transit'), 0) as funds_in_transit,
        coalesce(sum(balance), 0)                                                  as total_treasury
    from treasury_balances;

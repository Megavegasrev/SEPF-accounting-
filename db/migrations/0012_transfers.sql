-- =============================================================================
-- SEPF Treasury — Milestone 4 (Controls and transfers)
-- Migration 0012: Manual transfers between treasuries (funds in transit)
-- -----------------------------------------------------------------------------
-- Spec §10.3 / §5.3:
--   * no transfer is automatic and no percentage is imposed
--   * small->large: initiated by the Cashier, confirmed by the Accountant
--     large->small: initiated by the Accountant, confirmed by the Cashier
--   * on send: source decreases, funds-in-transit increases
--   * on confirm: funds-in-transit decreases, destination increases
--   * the confirmed amount equals the amount sent; partial transfers refused
--   * a transfer must NEVER change the consolidated treasury
-- The four legs (send x2, confirm x2) share the transfer id as movement_group_id
-- so each phase is balanced and the consolidated total is invariant throughout.
-- =============================================================================

create sequence seq_transfer_reference;
create or replace function next_transfer_reference()
returns text language sql as $$
    select 'TRF-' || to_char(now(), 'YYYY') || '-'
                  || lpad(nextval('seq_transfer_reference')::text, 6, '0');
$$;

create table internal_transfers (
    id                    uuid primary key default gen_random_uuid(),
    reference             text not null unique default next_transfer_reference(),
    idempotency_key       text not null unique,
    direction             text not null
                              check (direction in ('small_to_large','large_to_small')),
    amount                numeric(18,0) not null check (amount > 0),
    status                text not null default 'pending'
                              check (status in ('pending','confirmed','cancelled')),
    source_account_id     uuid not null references treasury_accounts(id),
    destination_account_id uuid not null references treasury_accounts(id),
    transit_account_id    uuid not null references treasury_accounts(id),
    initiated_by          uuid not null references users(id),
    initiated_at          timestamptz not null default now(),
    confirmed_by          uuid references users(id),
    confirmed_at          timestamptz,
    cancelled_by          uuid references users(id),
    cancelled_at          timestamptz,
    cancel_reason         text
);

create index idx_transfers_status on internal_transfers(status);
create index idx_transfers_direction on internal_transfers(direction);

comment on table internal_transfers is
    'Manual two-step transfers (§10.3). All movements live in the ledger; this '
    'table tracks the workflow state. status=cancelled is a proposed safeguard '
    'for the in-transit dead-end flagged in the spec review (see docs).';

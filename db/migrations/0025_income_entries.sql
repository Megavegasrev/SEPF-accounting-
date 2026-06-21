-- =============================================================================
-- SEPF Treasury — Production hardening (forward-only)
-- Migration 0025 (Priority 1.1): structured income_entries + record_income()
-- -----------------------------------------------------------------------------
-- An ordinary income now produces a structured income_entries row, a positive
-- treasury movement and an audit log, atomically and idempotently. Ordinary
-- income stays separate from capital contributions, borrowings, loan repayments
-- and internal transfers, which keep their own dedicated functions/tables.
-- NOTE: income_type / payment_method / project are text here and become foreign
-- keys to the protected reference tables in the reference-data migration
-- (inventory -> normalise -> backfill -> FK), per the approved plan.
-- =============================================================================

create table income_entries (
    id                 uuid primary key default gen_random_uuid(),
    movement_id        uuid not null references treasury_movements(id),
    account_id         uuid not null references treasury_accounts(id),
    amount             numeric(18,0) not null check (amount > 0),
    source_payer       text,
    income_type        text,
    purpose            text,
    operation_date     date not null default current_date,
    payment_method     text,
    external_reference text,
    project            text,
    recorded_by        uuid not null references users(id),
    idempotency_key    text not null unique,
    created_at         timestamptz not null default now()
);

create index idx_income_entries_account on income_entries(account_id, operation_date desc);
create index idx_income_entries_movement on income_entries(movement_id);

create trigger trg_income_entries_immutable
    before update or delete on income_entries
    for each row execute function trg_block_modification();

-- Replace record_income with the structured, atomic, idempotent version.
drop function if exists record_income(uuid, numeric, text, text, uuid);

create or replace function record_income(
    p_account_id        uuid,
    p_amount            numeric,
    p_idempotency_key   text,
    p_source_payer      text default null,
    p_income_type       text default null,
    p_purpose           text default null,
    p_operation_date    date default current_date,
    p_payment_method    text default null,
    p_external_reference text default null,
    p_project           text default null
)
returns income_entries
language plpgsql security definer set search_path = public
as $$
declare
    v_actor   uuid := app_current_user_id();
    v_account treasury_accounts;
    v_existing income_entries;
    v_movement treasury_movements;
    v_row     income_entries;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Income amount must be a positive integer' using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where id = p_account_id;
    if not found then
        raise exception 'Unknown treasury account %', p_account_id using errcode = '23503';
    end if;
    if v_account.account_type = 'small_treasury' then
        if not app_has_permission('income.record.small') then
            raise exception 'Not authorised to record small-treasury income' using errcode = '42501';
        end if;
    elsif v_account.account_type = 'large_treasury' then
        if not app_has_permission('income.record.large') then
            raise exception 'Not authorised to record large-treasury income' using errcode = '42501';
        end if;
    else
        raise exception 'Income cannot be recorded directly into the % account', v_account.account_type
            using errcode = '23514';
    end if;

    -- Idempotent replay: return the existing entry, no second movement/audit.
    select * into v_existing from income_entries where idempotency_key = p_idempotency_key;
    if found then
        return v_existing;
    end if;

    v_movement := post_treasury_movement(
        p_account_id, p_amount, 'income', p_idempotency_key, v_actor,
        'income_entry', null, null, null,
        coalesce(nullif(btrim(p_purpose), ''), nullif(btrim(p_source_payer), ''), 'Entrée d''argent'),
        'income.record');

    insert into income_entries (movement_id, account_id, amount, source_payer, income_type,
        purpose, operation_date, payment_method, external_reference, project, recorded_by, idempotency_key)
    values (v_movement.id, p_account_id, p_amount, p_source_payer, p_income_type, p_purpose,
        coalesce(p_operation_date, current_date), p_payment_method, p_external_reference, p_project,
        v_actor, p_idempotency_key)
    on conflict (idempotency_key) do nothing
    returning * into v_row;

    if v_row.id is null then
        select * into v_row from income_entries where idempotency_key = p_idempotency_key;
    end if;
    return v_row;
end;
$$;

-- RLS: read like the ledger (full readers, small-treasury reader, or the recorder).
alter table income_entries enable row level security;
create policy income_entries_read on income_entries
    for select using (
        app_has_permission('ledger.read.full')
        or recorded_by = app_current_user_id()
        or (app_has_permission('ledger.read.small')
            and account_id in (select id from treasury_accounts
                               where account_type in ('small_treasury','funds_in_transit')))
    );

grant select on income_entries to app_user;
grant execute on function record_income(uuid, numeric, text, text, text, text, date, text, text, text) to app_user;
grant select, insert, update, delete on income_entries to service_role;

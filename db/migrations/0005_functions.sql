-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Migration 0005: Transactional financial functions
-- -----------------------------------------------------------------------------
-- All financial postings go through SECURITY DEFINER functions, never through
-- direct INSERTs from the application role (§14.1 "API endpoints or
-- transactional functions for all financial postings"). The functions:
--   * re-check authority in the database (defence in depth, §14.2),
--   * are idempotent on idempotency_key (§13.1) — including the audit entry,
--     which is written exactly once per movement actually created,
--   * keep the ledger append-only — corrections happen via reverse_movement.
-- Foundation scope covers the §13.2 functions needed to demonstrate "balances
-- are calculated": record income, post a movement, reverse a movement.
-- Payments, transfers, salaries, controls, etc. arrive later and reuse
-- post_treasury_movement().
-- =============================================================================

-- -----------------------------------------------------------------------------
-- post_treasury_movement — low-level, idempotent ledger writer reused by every
-- higher-level operation. Signed amount: + inflow / - outflow.
-- When p_audit_action is supplied, an audit row is written ONLY if this call
-- actually inserted the movement, so retries and concurrent races never produce
-- duplicate audit entries. Returns the (possibly pre-existing) movement.
-- -----------------------------------------------------------------------------
create or replace function post_treasury_movement(
    p_account_id           uuid,
    p_amount               numeric,
    p_movement_type        text,
    p_idempotency_key      text,
    p_posted_by            uuid,
    p_source_type          text default null,
    p_source_id            uuid default null,
    p_movement_group_id    uuid default null,
    p_reverses_movement_id uuid default null,
    p_memo                 text default null,
    p_audit_action         text default null,
    p_audit_before         jsonb default null
)
returns treasury_movements
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row     treasury_movements;
    v_account treasury_accounts;
    v_created boolean := false;
begin
    if p_posted_by is null then
        raise exception 'post_treasury_movement requires an acting user'
            using errcode = '23502';
    end if;
    if p_amount is null or p_amount = 0 then
        raise exception 'Movement amount must be a non-zero integer'
            using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where id = p_account_id;
    if not found then
        raise exception 'Unknown treasury account %', p_account_id
            using errcode = '23503';
    end if;
    if not v_account.is_active then
        raise exception 'Treasury account % is inactive', v_account.code
            using errcode = '23514';
    end if;

    insert into treasury_movements (
        account_id, amount, movement_type, idempotency_key,
        movement_group_id, source_type, source_id,
        reverses_movement_id, memo, posted_by
    ) values (
        p_account_id, p_amount, p_movement_type, p_idempotency_key,
        p_movement_group_id, p_source_type, p_source_id,
        p_reverses_movement_id, p_memo, p_posted_by
    )
    on conflict (idempotency_key) do nothing
    returning * into v_row;

    if v_row.id is not null then
        v_created := true;
    else
        -- Idempotent replay (or lost race): return the original row unchanged.
        select * into v_row
        from treasury_movements
        where idempotency_key = p_idempotency_key;
    end if;

    -- Exactly-once audit: only the call that inserted the row records it.
    if v_created and p_audit_action is not null then
        insert into audit_logs (actor_user_id, action, entity_type, entity_id,
                                before, after)
        values (p_posted_by, p_audit_action, 'treasury_movement', v_row.id,
                p_audit_before, to_jsonb(v_row));
    end if;

    return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- record_income — §13.2 "Record income and its financial movement".
-- Positive movement; authority is scoped to the target treasury (§5/§4.2): the
-- Cashier records small-treasury income, the Accountant large-treasury income.
-- -----------------------------------------------------------------------------
create or replace function record_income(
    p_account_id      uuid,
    p_amount          numeric,
    p_idempotency_key text,
    p_memo            text default null,
    p_source_id       uuid default null
)
returns treasury_movements
language plpgsql
security definer
set search_path = public
as $$
declare
    v_actor   uuid := app_current_user_id();
    v_account treasury_accounts;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Income amount must be a positive integer'
            using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where id = p_account_id;
    if not found then
        raise exception 'Unknown treasury account %', p_account_id
            using errcode = '23503';
    end if;

    if v_account.account_type = 'small_treasury' then
        if not app_has_permission('income.record.small') then
            raise exception 'Not authorised to record small-treasury income'
                using errcode = '42501';
        end if;
    elsif v_account.account_type = 'large_treasury' then
        if not app_has_permission('income.record.large') then
            raise exception 'Not authorised to record large-treasury income'
                using errcode = '42501';
        end if;
    else
        raise exception 'Income cannot be recorded directly into the % account',
            v_account.account_type using errcode = '23514';
    end if;

    return post_treasury_movement(
        p_account_id, p_amount, 'income', p_idempotency_key, v_actor,
        'income_entry', p_source_id, null, null, p_memo,
        'income.record'
    );
end;
$$;

-- -----------------------------------------------------------------------------
-- reverse_movement — §13.2 "Create an adjustment or reversal". The only
-- sanctioned correction path (§5.4). Posts the opposite sign, links to the
-- original, demands a reason, refuses to reverse a reversal or to reverse the
-- same movement twice, and is itself idempotent on its key.
-- -----------------------------------------------------------------------------
create or replace function reverse_movement(
    p_movement_id     uuid,
    p_reason          text,
    p_idempotency_key text
)
returns treasury_movements
language plpgsql
security definer
set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_orig  treasury_movements;
    v_exist treasury_movements;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('movement.reverse') then
        raise exception 'Not authorised to reverse a movement'
            using errcode = '42501';
    end if;
    if coalesce(btrim(p_reason), '') = '' then
        raise exception 'A reason is mandatory for a reversal'
            using errcode = '23514';
    end if;

    select * into v_orig from treasury_movements where id = p_movement_id;
    if not found then
        raise exception 'Unknown movement %', p_movement_id
            using errcode = '23503';
    end if;
    if v_orig.movement_type = 'reversal' then
        raise exception 'A reversal cannot itself be reversed'
            using errcode = '23514';
    end if;

    -- Idempotent replay: a retry with the same key returns the same reversal
    -- instead of tripping the "already reversed" guard below.
    select * into v_exist
    from treasury_movements
    where idempotency_key = p_idempotency_key;
    if found then
        return v_exist;
    end if;

    if exists (select 1 from treasury_movements
               where reverses_movement_id = p_movement_id) then
        raise exception 'Movement % has already been reversed', p_movement_id
            using errcode = '23505';
    end if;

    return post_treasury_movement(
        v_orig.account_id, -v_orig.amount, 'reversal', p_idempotency_key, v_actor,
        'reversal', v_orig.id, v_orig.movement_group_id, v_orig.id, p_reason,
        'movement.reverse', to_jsonb(v_orig)
    );
end;
$$;

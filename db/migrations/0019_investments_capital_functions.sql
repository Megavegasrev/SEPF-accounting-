-- =============================================================================
-- SEPF Treasury — Milestone 6 (Investments and capital contributions)
-- Migration 0019: Transactional functions
--   create_investment · pay_investment
--   declare_capital_contribution · confirm_capital_contribution
-- =============================================================================

-- -----------------------------------------------------------------------------
-- create_investment — §9.1. Only a shareholder may create one; it becomes a
-- generic request (type investment, supplier as external beneficiary, large
-- treasury) that follows the normal approval workflow.
-- -----------------------------------------------------------------------------
create or replace function create_investment(
    p_amount            numeric,
    p_supplier          text,
    p_asset_name        text,
    p_asset_category    text,
    p_custodian_user_id uuid default null,
    p_custodian_name    text default null,
    p_project           text default null
)
returns investments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_req   requests;
    v_inv   investments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('investment.create') then
        raise exception 'Only a shareholder may create an SEPF investment (§9.1)'
            using errcode = '42501';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Investment amount must be a positive integer' using errcode = '23514';
    end if;

    insert into requests (request_type, requester_id)
    values ('investment', v_actor) returning * into v_req;

    insert into request_versions (request_id, version_number, amount,
        beneficiary_type, beneficiary_name, purpose, category,
        proposed_treasury, project, created_by)
    values (v_req.id, 1, p_amount, 'external', p_supplier,
            'Investment: ' || p_asset_name, p_asset_category,
            'large_treasury', p_project, v_actor);

    insert into investments (request_id, supplier, asset_name, asset_category,
                             custodian_user_id, custodian_name, created_by)
    values (v_req.id, p_supplier, p_asset_name, p_asset_category,
            p_custodian_user_id, p_custodian_name, v_actor)
    returning * into v_inv;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'investment.create', 'request', v_req.id, to_jsonb(v_inv));

    return v_inv;
end;
$$;

-- -----------------------------------------------------------------------------
-- pay_investment — §9.1. The Accountant pays the approved investment from the
-- large treasury and creates the asset register entry. Idempotent (returns the
-- existing asset on replay). Full amount only; insufficient funds pays nothing.
-- -----------------------------------------------------------------------------
create or replace function pay_investment(
    p_request_id  uuid,
    p_idempotency_key text,
    p_acquired_on date default null
)
returns assets
language plpgsql security definer set search_path = public
as $$
declare
    v_actor      uuid := app_current_user_id();
    v_inv        investments;
    v_version    request_versions;
    v_account    treasury_accounts;
    v_balance    numeric(18,0);
    v_existing   assets;
    v_payment_id uuid := gen_random_uuid();
    v_movement   treasury_movements;
    v_payment    payments;
    v_asset      assets;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('investment.pay') then
        raise exception 'Not authorised to pay an investment (§9.1)' using errcode = '42501';
    end if;

    select * into v_inv from investments where request_id = p_request_id;
    if not found then
        raise exception 'Request % is not an investment', p_request_id using errcode = '23503';
    end if;

    select * into v_existing from assets where investment_id = v_inv.id;
    if found then
        return v_existing;   -- idempotent
    end if;

    select * into v_version from request_versions
    where request_id = p_request_id and status = 'approved';
    if not found then
        raise exception 'The investment has no approved version to pay' using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where account_type = 'large_treasury' for update;
    select v_account.opening_balance + coalesce(sum(m.amount), 0) into v_balance
    from treasury_movements m where m.account_id = v_account.id;
    if v_balance < v_version.amount then
        raise exception 'Insufficient large treasury: nothing is paid (§6.7)' using errcode = '23514';
    end if;

    v_movement := post_treasury_movement(v_account.id, -v_version.amount, 'investment',
        p_idempotency_key, v_actor, 'payment', v_payment_id, null, null,
        'Investment payment', 'investment.pay');

    insert into payments (id, request_id, request_version_id, treasury_account_id,
                          amount, movement_id, is_advance, status, paid_by)
    values (v_payment_id, p_request_id, v_version.id, v_account.id,
            v_version.amount, v_movement.id, false, 'completed', v_actor)
    returning * into v_payment;

    insert into assets (investment_id, cost, acquired_on, custodian_user_id,
                        custodian_name, payment_id, movement_id, created_by)
    values (v_inv.id, v_version.amount, coalesce(p_acquired_on, current_date),
            v_inv.custodian_user_id, v_inv.custodian_name, v_payment.id,
            v_movement.id, v_actor)
    returning * into v_asset;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'investment.pay', 'asset', v_asset.id, to_jsonb(v_asset));

    return v_asset;
end;
$$;

-- -----------------------------------------------------------------------------
-- declare_capital_contribution — §9.2. A shareholder declares their OWN
-- contribution. No approval workflow; the large treasury stays unchanged until
-- the Accountant confirms receipt.
-- -----------------------------------------------------------------------------
create or replace function declare_capital_contribution(p_amount numeric)
returns capital_contributions
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_row   capital_contributions;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('capital.contribute') then
        raise exception 'Only a shareholder may declare a capital contribution (§9.2)'
            using errcode = '42501';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Contribution amount must be a positive integer' using errcode = '23514';
    end if;

    insert into capital_contributions (shareholder_user_id, amount, declared_by)
    values (v_actor, p_amount, v_actor)
    returning * into v_row;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'capital.declare', 'capital_contribution', v_row.id, to_jsonb(v_row));

    return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- confirm_capital_contribution — §9.2. The Accountant confirms or refuses full
-- receipt. On confirmation the large treasury increases; refusal needs a cause
-- and posts nothing. Idempotent on its key.
-- -----------------------------------------------------------------------------
create or replace function confirm_capital_contribution(
    p_contribution_id uuid,
    p_confirmed       boolean,
    p_idempotency_key text,
    p_cause           text default null
)
returns capital_contributions
language plpgsql security definer set search_path = public
as $$
declare
    v_actor    uuid := app_current_user_id();
    v_row      capital_contributions;
    v_account  treasury_accounts;
    v_movement treasury_movements;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('capital.confirm') then
        raise exception 'Not authorised to confirm a capital contribution (§9.2)'
            using errcode = '42501';
    end if;

    select * into v_row from capital_contributions where id = p_contribution_id for update;
    if not found then
        raise exception 'Unknown capital contribution %', p_contribution_id using errcode = '23503';
    end if;
    if v_row.status <> 'awaiting_receipt' then
        if v_row.confirm_idempotency_key = p_idempotency_key then
            return v_row;   -- idempotent replay
        end if;
        raise exception 'This contribution has already been processed' using errcode = '23505';
    end if;

    if p_confirmed then
        select * into v_account from treasury_accounts where account_type='large_treasury' for update;
        v_movement := post_treasury_movement(v_account.id, v_row.amount, 'capital_contribution',
            p_idempotency_key, v_actor, 'capital_contribution', v_row.id, null, null,
            'Capital contribution received', 'capital.confirm');

        update capital_contributions
        set status='confirmed', confirmed_by=v_actor, confirmed_at=now(),
            movement_id=v_movement.id, confirm_idempotency_key=p_idempotency_key
        where id = p_contribution_id returning * into v_row;
    else
        if coalesce(btrim(p_cause),'') = '' then
            raise exception 'A cause is mandatory when receipt is not confirmed (§9.2)'
                using errcode = '23514';
        end if;
        update capital_contributions
        set status='not_confirmed', confirmed_by=v_actor, confirmed_at=now(),
            not_confirmed_cause=btrim(p_cause), confirm_idempotency_key=p_idempotency_key
        where id = p_contribution_id returning * into v_row;
    end if;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'capital.confirm', 'capital_contribution', p_contribution_id, to_jsonb(v_row));

    return v_row;
end;
$$;

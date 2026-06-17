-- =============================================================================
-- SEPF Treasury — Milestone 3 (Requests and expenses)
-- Migration 0009: Transactional functions for the request lifecycle
-- -----------------------------------------------------------------------------
-- The universal workflow (§4.1): create -> first approval -> final approval ->
-- payment -> control. Control is milestone 4. Every function is SECURITY
-- DEFINER, re-checks authority in the database, and keeps decisions append-only.
-- Self-approval is permitted (§4.1) but flagged via is_self_decision.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- create_request — creates the request and its version 1 (pending first
-- approval). Any role may create a request (§4.2).
-- -----------------------------------------------------------------------------
create or replace function create_request(
    p_amount              numeric,
    p_beneficiary_type    text,
    p_purpose             text,
    p_category            text,
    p_proposed_treasury   text,
    p_beneficiary_user_id uuid default null,
    p_beneficiary_name    text default null,
    p_project             text default null,
    p_urgency             text default 'normal',
    p_desired_date        date default null
)
returns requests
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_req   requests;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('request.create') then
        raise exception 'Not authorised to create a request' using errcode = '42501';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Requested amount must be a positive integer'
            using errcode = '23514';
    end if;

    insert into requests (requester_id) values (v_actor) returning * into v_req;

    insert into request_versions (
        request_id, version_number, amount, beneficiary_type,
        beneficiary_user_id, beneficiary_name, purpose, category,
        proposed_treasury, project, urgency, desired_date, created_by
    ) values (
        v_req.id, 1, p_amount, p_beneficiary_type,
        p_beneficiary_user_id, p_beneficiary_name, p_purpose, p_category,
        p_proposed_treasury, p_project, coalesce(p_urgency,'normal'),
        p_desired_date, v_actor
    );

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'request.create', 'request', v_req.id, to_jsonb(v_req));

    return v_req;
end;
$$;

-- -----------------------------------------------------------------------------
-- create_request_correction — submits a new version (§6.3). Only the requester,
-- only while a version is still live, and never once a payment exists.
-- -----------------------------------------------------------------------------
create or replace function create_request_correction(
    p_request_id          uuid,
    p_amount              numeric,
    p_beneficiary_type    text,
    p_purpose             text,
    p_category            text,
    p_proposed_treasury   text,
    p_beneficiary_user_id uuid default null,
    p_beneficiary_name    text default null,
    p_project             text default null,
    p_urgency             text default 'normal',
    p_desired_date        date default null
)
returns request_versions
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_req   requests;
    v_live  request_versions;
    v_new   request_versions;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;

    select * into v_req from requests where id = p_request_id;
    if not found then
        raise exception 'Unknown request %', p_request_id using errcode = '23503';
    end if;
    if v_req.requester_id <> v_actor or not app_has_permission('request.create') then
        raise exception 'Only the requester may correct this request'
            using errcode = '42501';
    end if;
    if exists (select 1 from payments where request_id = p_request_id) then
        raise exception 'A request that has been paid or disbursed cannot be corrected'
            using errcode = '23514';
    end if;

    select * into v_live from request_versions
    where request_id = p_request_id
      and status in ('pending_first','pending_final','correction_requested')
    order by version_number desc limit 1;
    if not found then
        raise exception 'There is no live version to correct'
            using errcode = '23514';
    end if;

    update request_versions set status = 'superseded' where id = v_live.id;

    insert into request_versions (
        request_id, version_number, amount, beneficiary_type,
        beneficiary_user_id, beneficiary_name, purpose, category,
        proposed_treasury, project, urgency, desired_date, created_by
    ) values (
        p_request_id, v_live.version_number + 1, p_amount, p_beneficiary_type,
        p_beneficiary_user_id, p_beneficiary_name, p_purpose, p_category,
        p_proposed_treasury, p_project, coalesce(p_urgency,'normal'),
        p_desired_date, v_actor
    ) returning * into v_new;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'request.correct', 'request_version', v_new.id,
            to_jsonb(v_new));

    return v_new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Internal helper: apply a decision to a version, keep an append-only record,
-- transition the version status and reconcile any advance disbursement (§6.5).
-- Used by the first- and final-level wrappers so the rules live in one place.
-- -----------------------------------------------------------------------------
create or replace function apply_validation(
    p_version_id uuid,
    p_level      text,
    p_decision   text,
    p_comment    text
)
returns request_validations
language plpgsql security definer set search_path = public
as $$
declare
    v_actor    uuid := app_current_user_id();
    v_version  request_versions;
    v_req      requests;
    v_new      text;
    v_val      request_validations;
    v_has_adv  boolean;
begin
    if p_decision not in ('approved','not_approved','correction_requested') then
        raise exception 'Invalid decision %', p_decision using errcode = '23514';
    end if;
    if p_decision <> 'approved' and coalesce(btrim(p_comment),'') = '' then
        raise exception 'A comment is mandatory for "%"', p_decision
            using errcode = '23514';
    end if;

    select * into v_version from request_versions where id = p_version_id for update;
    if not found then
        raise exception 'Unknown request version %', p_version_id
            using errcode = '23503';
    end if;

    -- Sequence guard (§6.2): first decides a pending_first version; final can
    -- only act once the first level has approved (version is pending_final).
    if p_level = 'first' and v_version.status <> 'pending_first' then
        raise exception 'This version is not awaiting first-level approval'
            using errcode = '23514';
    end if;
    if p_level = 'final' and v_version.status <> 'pending_final' then
        raise exception 'Final approval requires a completed first approval first'
            using errcode = '23514';
    end if;

    select * into v_req from requests where id = v_version.request_id;

    v_has_adv := exists (select 1 from payments
                         where request_id = v_req.id and status = 'disbursed_pending');
    -- A correction cannot be requested once cash has been advanced (§6.5): the
    -- amount is committed, so the only outcomes are approve or refuse.
    if v_has_adv and p_decision = 'correction_requested' then
        raise exception 'Cannot request a correction after an advance disbursement'
            using errcode = '23514';
    end if;

    insert into request_validations (request_version_id, level, decision, comment,
                                     is_self_decision, decided_by)
    values (p_version_id, p_level, p_decision, nullif(btrim(p_comment),''),
            (v_actor = v_req.requester_id), v_actor)
    returning * into v_val;

    v_new := case
        when p_decision = 'not_approved'         then 'rejected'
        when p_decision = 'correction_requested' then 'correction_requested'
        when p_level = 'first'                   then 'pending_final'
        else 'approved'
    end;
    update request_versions set status = v_new where id = p_version_id;

    -- Reconcile an advance: approval completes it; refusal marks it
    -- "disbursed - not approved" and NEVER credits the treasury back (§6.5).
    if v_has_adv then
        if v_new = 'approved' then
            update payments set status = 'completed'
            where request_id = v_req.id and status = 'disbursed_pending';
        elsif v_new = 'rejected' then
            update payments set status = 'disbursed_unapproved'
            where request_id = v_req.id and status = 'disbursed_pending';
        end if;
    end if;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'request.decision.' || p_level, 'request_version',
            p_version_id, to_jsonb(v_val));

    return v_val;
end;
$$;

create or replace function record_first_validation(
    p_version_id uuid, p_decision text, p_comment text default null
)
returns request_validations
language plpgsql security definer set search_path = public
as $$
begin
    if app_current_user_id() is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('request.approve.first') then
        raise exception 'Not authorised to give first-level approval'
            using errcode = '42501';
    end if;
    return apply_validation(p_version_id, 'first', p_decision, p_comment);
end;
$$;

create or replace function record_final_validation(
    p_version_id uuid, p_decision text, p_comment text default null
)
returns request_validations
language plpgsql security definer set search_path = public
as $$
begin
    if app_current_user_id() is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('request.approve.final') then
        raise exception 'Not authorised to give final approval' using errcode = '42501';
    end if;
    return apply_validation(p_version_id, 'final', p_decision, p_comment);
end;
$$;

-- -----------------------------------------------------------------------------
-- pay_request — normal payment after both approvals (§6.6/§6.7). Full amount
-- only, equal to the approved version, from the approved version's treasury, by
-- the role that owns that treasury. Insufficient balance => nothing is paid.
-- -----------------------------------------------------------------------------
create or replace function pay_request(
    p_request_id uuid, p_idempotency_key text
)
returns payments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor      uuid := app_current_user_id();
    v_version    request_versions;
    v_account    treasury_accounts;
    v_balance    numeric(18,0);
    v_payment_id uuid := gen_random_uuid();
    v_movement   treasury_movements;
    v_payment    payments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;

    -- Idempotent replay.
    select * into v_payment from payments where request_id = p_request_id;
    if found then
        if v_payment.is_advance then
            raise exception 'This request was disbursed as an advance; use the advance flow'
                using errcode = '23505';
        end if;
        return v_payment;
    end if;

    select * into v_version from request_versions
    where request_id = p_request_id and status = 'approved';
    if not found then
        raise exception 'Request % has no approved version to pay', p_request_id
            using errcode = '23514';
    end if;

    if v_version.proposed_treasury = 'small_treasury' then
        if not app_has_permission('expense.pay.small') then
            raise exception 'Not authorised to pay from the small treasury'
                using errcode = '42501';
        end if;
    else
        if not app_has_permission('expense.pay.large') then
            raise exception 'Not authorised to pay from the large treasury'
                using errcode = '42501';
        end if;
    end if;

    -- Lock the treasury row to serialise concurrent payments to it, then derive
    -- the live balance from the ledger.
    select * into v_account from treasury_accounts
    where account_type = v_version.proposed_treasury for update;

    select v_account.opening_balance + coalesce(sum(m.amount), 0)
    into v_balance
    from treasury_movements m where m.account_id = v_account.id;

    if v_balance < v_version.amount then
        raise exception
            'Insufficient balance: nothing is paid and the request stays pending (§6.7)'
            using errcode = '23514';
    end if;

    v_movement := post_treasury_movement(
        v_account.id, -v_version.amount, 'expense', p_idempotency_key, v_actor,
        'payment', v_payment_id, null, null, 'Payment of request',
        'expense.pay');

    insert into payments (id, request_id, request_version_id, treasury_account_id,
                          amount, movement_id, is_advance, status, paid_by)
    values (v_payment_id, p_request_id, v_version.id, v_account.id,
            v_version.amount, v_movement.id, false, 'completed', v_actor)
    returning * into v_payment;

    return v_payment;
end;
$$;

-- -----------------------------------------------------------------------------
-- disburse_small_advance — §6.5 the Cashier disburses a small expense BEFORE
-- approval; the movement posts immediately. Small treasury only, Cashier only,
-- on a still-live version. A later refusal never credits the treasury back.
-- -----------------------------------------------------------------------------
create or replace function disburse_small_advance(
    p_request_id uuid, p_idempotency_key text
)
returns payments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor      uuid := app_current_user_id();
    v_version    request_versions;
    v_account    treasury_accounts;
    v_balance    numeric(18,0);
    v_payment_id uuid := gen_random_uuid();
    v_movement   treasury_movements;
    v_payment    payments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('expense.disburse_advance') then
        raise exception 'Not authorised to disburse an advance' using errcode = '42501';
    end if;

    select * into v_payment from payments where request_id = p_request_id;
    if found then
        return v_payment;  -- idempotent: already disbursed/paid
    end if;

    select * into v_version from request_versions
    where request_id = p_request_id
      and status in ('pending_first','pending_final')
    order by version_number desc limit 1;
    if not found then
        raise exception 'No live version available to disburse' using errcode = '23514';
    end if;
    if v_version.proposed_treasury <> 'small_treasury' then
        raise exception 'Advance disbursement is reserved for the small treasury (§6.5)'
            using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts
    where account_type = 'small_treasury' for update;

    select v_account.opening_balance + coalesce(sum(m.amount), 0)
    into v_balance
    from treasury_movements m where m.account_id = v_account.id;

    if v_balance < v_version.amount then
        raise exception 'Insufficient small-treasury balance to disburse'
            using errcode = '23514';
    end if;

    v_movement := post_treasury_movement(
        v_account.id, -v_version.amount, 'expense', p_idempotency_key, v_actor,
        'payment', v_payment_id, null, null, 'Advance disbursement before approval',
        'expense.disburse_advance');

    insert into payments (id, request_id, request_version_id, treasury_account_id,
                          amount, movement_id, is_advance, status, paid_by)
    values (v_payment_id, p_request_id, v_version.id, v_account.id,
            v_version.amount, v_movement.id, true, 'disbursed_pending', v_actor)
    returning * into v_payment;

    return v_payment;
end;
$$;

-- =============================================================================
-- SEPF Treasury — Database review fixes
-- Migration 0024: harden create_request_correction
-- -----------------------------------------------------------------------------
-- Finding (database review): create_request_correction is generic and could be
-- applied to a specialised request (salary_advance / investment / loan /
-- borrowing_repayment). A correction changes the request VERSION amount but not
-- the linked specialised record (loans_granted.principal, borrowing_installments
-- parts, salary_advance_requests.amount), which would let those denormalised
-- figures drift from the approved version. The versioning/correction concept is
-- defined only for expense requests (§6.3); specialised requests are replaced by
-- submitting a new one. We therefore restrict corrections to 'expense' requests.
-- =============================================================================

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
    -- Review fix: only expense requests support the §6.3 correction/versioning
    -- flow; specialised requests are replaced by submitting a new one.
    if v_req.request_type <> 'expense' then
        raise exception
            'Only expense requests can be corrected; submit a new % request instead (§6.3)',
            v_req.request_type using errcode = '23514';
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

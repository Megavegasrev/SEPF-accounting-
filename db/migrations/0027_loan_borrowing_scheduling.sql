-- =============================================================================
-- SEPF Treasury — Production hardening (forward-only)
-- Migration 0027 (Priority 1.3 & 1.4): loan due dates + borrowing schedule
-- =============================================================================

-- --- 1.4 Loan installment due dates are mandatory while scheduled -------------
alter table loan_repayments
    add constraint chk_loan_scheduled_due_date
    check (status <> 'scheduled' or due_date is not null);

create or replace function add_loan_installment(
    p_loan_id uuid, p_amount numeric, p_due_date date default null
)
returns loan_repayments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_loan  loans_granted;
    v_scheduled numeric(18,0);
    v_row   loan_repayments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('loan.manage') then
        raise exception 'Not authorised to manage loan repayments' using errcode = '42501';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Instalment amount must be a positive integer' using errcode = '23514';
    end if;
    if p_due_date is null then
        raise exception 'A due date is required for a scheduled loan installment' using errcode = '23514';
    end if;

    select * into v_loan from loans_granted where id = p_loan_id;
    if not found then
        raise exception 'Unknown loan %', p_loan_id using errcode = '23503';
    end if;
    if v_loan.status <> 'disbursed' then
        raise exception 'Only a disbursed loan can have a repayment schedule' using errcode = '23514';
    end if;

    select coalesce(sum(amount), 0) into v_scheduled from loan_repayments where loan_id = p_loan_id;
    if v_scheduled + p_amount > v_loan.principal then
        raise exception 'Scheduled instalments would exceed the loan principal' using errcode = '23514';
    end if;

    insert into loan_repayments (loan_id, amount, due_date)
    values (p_loan_id, p_amount, p_due_date) returning * into v_row;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'loan.schedule', 'loan', p_loan_id, to_jsonb(v_row));

    return v_row;
end;
$$;

-- --- 1.3 Borrowing repayment scheduling --------------------------------------
alter table borrowing_installments add column installment_number int;
alter table borrowing_installments add column due_date date;
alter table borrowing_installments
    add constraint chk_installment_number_positive
    check (installment_number is null or installment_number > 0);

-- request_borrowing_repayment gains optional schedule fields (full payment only
-- and principal<=outstanding are unchanged). New signature -> drop + recreate.
drop function if exists request_borrowing_repayment(uuid, numeric, numeric, numeric);

create or replace function request_borrowing_repayment(
    p_borrowing_id     uuid,
    p_principal_part   numeric,
    p_interest_part    numeric default 0,
    p_charges_part     numeric default 0,
    p_installment_number int default null,
    p_due_date         date default null
)
returns borrowing_installments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor   uuid := app_current_user_id();
    v_borrow  company_borrowings;
    v_repaid  numeric(18,0);
    v_total   numeric(18,0);
    v_req     requests;
    v_inst    borrowing_installments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('request.create') then
        raise exception 'Not authorised to create a request' using errcode = '42501';
    end if;

    select * into v_borrow from company_borrowings where id = p_borrowing_id;
    if not found then
        raise exception 'Unknown borrowing %', p_borrowing_id using errcode = '23503';
    end if;
    if v_borrow.status <> 'received' then
        raise exception 'Only a received borrowing can be repaid' using errcode = '23514';
    end if;

    v_total := coalesce(p_principal_part,0) + coalesce(p_interest_part,0) + coalesce(p_charges_part,0);
    if v_total <= 0 then
        raise exception 'A repayment instalment must be positive' using errcode = '23514';
    end if;

    select coalesce(sum(principal_part),0) into v_repaid
    from borrowing_installments where borrowing_id = p_borrowing_id and status = 'paid';
    if v_repaid + coalesce(p_principal_part,0) > v_borrow.principal then
        raise exception 'Principal repaid would exceed the outstanding liability' using errcode = '23514';
    end if;

    insert into requests (request_type, requester_id)
    values ('borrowing_repayment', v_actor) returning * into v_req;

    insert into request_versions (request_id, version_number, amount, beneficiary_type,
        beneficiary_name, purpose, category, proposed_treasury, created_by)
    values (v_req.id, 1, v_total, 'external', v_borrow.lender_name,
            'Borrowing repayment', 'borrowing_repayment', 'large_treasury', v_actor);

    insert into borrowing_installments (borrowing_id, request_id, principal_part, interest_part,
        charges_part, installment_number, due_date)
    values (p_borrowing_id, v_req.id, coalesce(p_principal_part,0), coalesce(p_interest_part,0),
            coalesce(p_charges_part,0), p_installment_number, p_due_date)
    returning * into v_inst;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'borrowing.repay.request', 'request', v_req.id, to_jsonb(v_inst));

    return v_inst;
end;
$$;

grant execute on function add_loan_installment(uuid, numeric, date) to app_user;
grant execute on function request_borrowing_repayment(uuid, numeric, numeric, numeric, int, date) to app_user;

-- Schedule read-model: classify each pending instalment as upcoming/due/overdue.
create view borrowing_installment_schedule
with (security_invoker = true) as
    select i.id as installment_id,
           i.borrowing_id,
           b.reference        as borrowing_reference,
           b.lender_name,
           i.installment_number,
           i.due_date,
           i.principal_part + i.interest_part + i.charges_part as total_due,
           i.principal_part, i.interest_part, i.charges_part,
           i.status,
           case
               when i.status = 'paid' then 'paid'
               when i.due_date is null then 'unscheduled'
               when i.due_date < current_date then 'overdue'
               when i.due_date <= current_date + 7 then 'due_soon'
               else 'upcoming'
           end as schedule_state
    from borrowing_installments i
    join company_borrowings b on b.id = i.borrowing_id;

grant select on borrowing_installment_schedule to app_user;

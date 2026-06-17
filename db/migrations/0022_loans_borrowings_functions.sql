-- =============================================================================
-- SEPF Treasury — Milestone 7 (Loans, borrowings and reports)
-- Migration 0022: Transactional functions
--   Loans:      create_loan_request · disburse_loan · add_loan_installment
--               · record_loan_repayment
--   Borrowings: enter_borrowing · confirm_borrowing_receipt
--               · request_borrowing_repayment · pay_borrowing_repayment
-- =============================================================================

-- ===== Loans granted by SEPF (§10.1) =========================================

-- create_loan_request — any user; a request of type 'loan' (external borrower,
-- large treasury) following the normal approval workflow.
create or replace function create_loan_request(
    p_amount        numeric,
    p_borrower_name text,
    p_purpose       text default 'Loan granted',
    p_project       text default null
)
returns loans_granted
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_req   requests;
    v_loan  loans_granted;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('request.create') then
        raise exception 'Not authorised to create a request' using errcode = '42501';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Loan amount must be a positive integer' using errcode = '23514';
    end if;

    insert into requests (request_type, requester_id)
    values ('loan', v_actor) returning * into v_req;

    insert into request_versions (request_id, version_number, amount,
        beneficiary_type, beneficiary_name, purpose, category,
        proposed_treasury, project, created_by)
    values (v_req.id, 1, p_amount, 'external', p_borrower_name, p_purpose,
            'loan', 'large_treasury', p_project, v_actor);

    insert into loans_granted (request_id, borrower_name, principal, created_by)
    values (v_req.id, p_borrower_name, p_amount, v_actor)
    returning * into v_loan;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'loan.request', 'request', v_req.id, to_jsonb(v_loan));

    return v_loan;
end;
$$;

-- disburse_loan — Accountant disburses the full approved amount from the large
-- treasury, creating the receivable. Not an ordinary expense (no payments row).
create or replace function disburse_loan(p_request_id uuid, p_idempotency_key text)
returns loans_granted
language plpgsql security definer set search_path = public
as $$
declare
    v_actor    uuid := app_current_user_id();
    v_loan     loans_granted;
    v_version  request_versions;
    v_account  treasury_accounts;
    v_balance  numeric(18,0);
    v_movement treasury_movements;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('loan.disburse') then
        raise exception 'Not authorised to disburse a loan (§10.1)' using errcode = '42501';
    end if;

    select * into v_loan from loans_granted where request_id = p_request_id;
    if not found then
        raise exception 'Request % is not a loan', p_request_id using errcode = '23503';
    end if;
    if v_loan.status = 'disbursed' then
        return v_loan;   -- idempotent
    end if;

    select * into v_version from request_versions
    where request_id = p_request_id and status = 'approved';
    if not found then
        raise exception 'The loan has no approved version to disburse' using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where account_type = 'large_treasury' for update;
    select v_account.opening_balance + coalesce(sum(m.amount), 0) into v_balance
    from treasury_movements m where m.account_id = v_account.id;
    if v_balance < v_version.amount then
        raise exception 'Insufficient large treasury: nothing is disbursed (§6.7)' using errcode = '23514';
    end if;

    v_movement := post_treasury_movement(v_account.id, -v_version.amount, 'loan_disbursement',
        p_idempotency_key, v_actor, 'loan', v_loan.id, null, null,
        'Loan disbursement (receivable)', 'loan.disburse');

    update loans_granted set status = 'disbursed', disbursement_movement_id = v_movement.id,
           disbursed_by = v_actor, disbursed_at = now()
    where id = v_loan.id returning * into v_loan;

    return v_loan;
end;
$$;

-- add_loan_installment — schedule a repayment instalment (cannot exceed what is
-- still owed). For the loan manager (loan.manage).
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

-- record_loan_repayment — a scheduled instalment is received: the large treasury
-- increases and the receivable falls. Full amount only; idempotent.
create or replace function record_loan_repayment(p_installment_id uuid, p_idempotency_key text)
returns loan_repayments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor    uuid := app_current_user_id();
    v_inst     loan_repayments;
    v_loan     loans_granted;
    v_received numeric(18,0);
    v_account  treasury_accounts;
    v_movement treasury_movements;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('loan.manage') then
        raise exception 'Not authorised to record a loan repayment' using errcode = '42501';
    end if;

    select * into v_inst from loan_repayments where id = p_installment_id;
    if not found then
        raise exception 'Unknown instalment %', p_installment_id using errcode = '23503';
    end if;
    if v_inst.status = 'received' then
        return v_inst;   -- idempotent
    end if;

    select * into v_loan from loans_granted where id = v_inst.loan_id;
    select coalesce(sum(amount), 0) into v_received
    from loan_repayments where loan_id = v_loan.id and status = 'received';
    if v_received + v_inst.amount > v_loan.principal then
        raise exception 'Repayment would exceed the outstanding receivable' using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where account_type = 'large_treasury' for update;
    v_movement := post_treasury_movement(v_account.id, v_inst.amount, 'loan_repayment',
        p_idempotency_key, v_actor, 'loan_repayment', v_inst.id, null, null,
        'Loan repayment received', 'loan.repay');

    update loan_repayments set status = 'received', movement_id = v_movement.id,
           idempotency_key = p_idempotency_key, received_by = v_actor, received_at = now()
    where id = p_installment_id returning * into v_inst;

    return v_inst;
end;
$$;

-- ===== Borrowings obtained by SEPF (§10.2) ===================================

-- enter_borrowing — recorded administratively; the large treasury is unchanged
-- until receipt is confirmed.
create or replace function enter_borrowing(p_lender_name text, p_principal numeric)
returns company_borrowings
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_row   company_borrowings;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('borrowing.enter') then
        raise exception 'Not authorised to enter a borrowing (§10.2)' using errcode = '42501';
    end if;
    if p_principal is null or p_principal <= 0 then
        raise exception 'Borrowing principal must be a positive integer' using errcode = '23514';
    end if;

    insert into company_borrowings (lender_name, principal, entered_by)
    values (p_lender_name, p_principal, v_actor) returning * into v_row;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'borrowing.enter', 'company_borrowing', v_row.id, to_jsonb(v_row));

    return v_row;
end;
$$;

-- confirm_borrowing_receipt — the Accountant confirms (or refuses) receipt. On
-- confirmation the large treasury increases; refusal needs a cause. Idempotent.
create or replace function confirm_borrowing_receipt(
    p_borrowing_id uuid, p_confirmed boolean, p_idempotency_key text, p_cause text default null
)
returns company_borrowings
language plpgsql security definer set search_path = public
as $$
declare
    v_actor    uuid := app_current_user_id();
    v_row      company_borrowings;
    v_account  treasury_accounts;
    v_movement treasury_movements;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('borrowing.confirm') then
        raise exception 'Not authorised to confirm a borrowing (§10.2)' using errcode = '42501';
    end if;

    select * into v_row from company_borrowings where id = p_borrowing_id for update;
    if not found then
        raise exception 'Unknown borrowing %', p_borrowing_id using errcode = '23503';
    end if;
    if v_row.status <> 'awaiting_receipt' then
        if v_row.confirm_idempotency_key = p_idempotency_key then
            return v_row;
        end if;
        raise exception 'This borrowing has already been processed' using errcode = '23505';
    end if;

    if p_confirmed then
        select * into v_account from treasury_accounts where account_type='large_treasury' for update;
        v_movement := post_treasury_movement(v_account.id, v_row.principal, 'borrowing_receipt',
            p_idempotency_key, v_actor, 'borrowing', v_row.id, null, null,
            'Borrowing received', 'borrowing.confirm');
        update company_borrowings
        set status='received', confirmed_by=v_actor, confirmed_at=now(),
            receipt_movement_id=v_movement.id, confirm_idempotency_key=p_idempotency_key
        where id = p_borrowing_id returning * into v_row;
    else
        if coalesce(btrim(p_cause),'') = '' then
            raise exception 'A cause is mandatory when receipt is not confirmed (§10.2)'
                using errcode = '23514';
        end if;
        update company_borrowings
        set status='not_received', confirmed_by=v_actor, confirmed_at=now(),
            not_received_cause=btrim(p_cause), confirm_idempotency_key=p_idempotency_key
        where id = p_borrowing_id returning * into v_row;
    end if;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'borrowing.confirm', 'company_borrowing', p_borrowing_id, to_jsonb(v_row));

    return v_row;
end;
$$;

-- request_borrowing_repayment — a repayment request (dual approval), splitting
-- principal / interest / charges (§10.2). Principal cannot exceed what is owed.
create or replace function request_borrowing_repayment(
    p_borrowing_id  uuid,
    p_principal_part numeric,
    p_interest_part  numeric default 0,
    p_charges_part   numeric default 0
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

    insert into request_versions (request_id, version_number, amount,
        beneficiary_type, beneficiary_name, purpose, category, proposed_treasury, created_by)
    values (v_req.id, 1, v_total, 'external', v_borrow.lender_name,
            'Borrowing repayment', 'borrowing_repayment', 'large_treasury', v_actor);

    insert into borrowing_installments (borrowing_id, request_id, principal_part,
                                        interest_part, charges_part)
    values (p_borrowing_id, v_req.id, coalesce(p_principal_part,0),
            coalesce(p_interest_part,0), coalesce(p_charges_part,0))
    returning * into v_inst;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'borrowing.repay.request', 'request', v_req.id, to_jsonb(v_inst));

    return v_inst;
end;
$$;

-- pay_borrowing_repayment — Accountant pays the approved repayment in full from
-- the large treasury, reducing the liability. Idempotent.
create or replace function pay_borrowing_repayment(p_request_id uuid, p_idempotency_key text)
returns borrowing_installments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor    uuid := app_current_user_id();
    v_inst     borrowing_installments;
    v_version  request_versions;
    v_account  treasury_accounts;
    v_balance  numeric(18,0);
    v_movement treasury_movements;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('borrowing.repay') then
        raise exception 'Not authorised to pay a borrowing repayment (§10.2)' using errcode = '42501';
    end if;

    select * into v_inst from borrowing_installments where request_id = p_request_id;
    if not found then
        raise exception 'Request % is not a borrowing repayment', p_request_id using errcode = '23503';
    end if;
    if v_inst.status = 'paid' then
        return v_inst;   -- idempotent
    end if;

    select * into v_version from request_versions
    where request_id = p_request_id and status = 'approved';
    if not found then
        raise exception 'The repayment has no approved version to pay' using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where account_type = 'large_treasury' for update;
    select v_account.opening_balance + coalesce(sum(m.amount), 0) into v_balance
    from treasury_movements m where m.account_id = v_account.id;
    if v_balance < v_version.amount then
        raise exception 'Insufficient large treasury: nothing is paid (§6.7)' using errcode = '23514';
    end if;

    v_movement := post_treasury_movement(v_account.id, -v_version.amount, 'borrowing_repayment',
        p_idempotency_key, v_actor, 'borrowing_repayment', v_inst.id, null, null,
        'Borrowing repayment', 'borrowing.repay');

    update borrowing_installments set status='paid', payment_movement_id=v_movement.id,
           paid_by=v_actor, paid_at=now()
    where id = v_inst.id returning * into v_inst;

    return v_inst;
end;
$$;

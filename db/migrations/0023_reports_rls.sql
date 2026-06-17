-- =============================================================================
-- SEPF Treasury — Milestone 7 (Loans, borrowings and reports)
-- Migration 0023: reporting views, export audit, RLS and grants
-- -----------------------------------------------------------------------------
-- §11 history/reports/exports. The actual files (PDF/Excel/CSV) are produced by
-- the frontend from these read models; the database supplies the data and the
-- audit record (§11.3 "every export must be recorded in the audit trail").
-- =============================================================================

-- -----------------------------------------------------------------------------
-- v_transaction_history — the §11.1 general history timeline. security_invoker,
-- so the caller's ledger RLS decides which movements are visible.
-- -----------------------------------------------------------------------------
create view v_transaction_history
with (security_invoker = true) as
    select m.id              as movement_id,
           m.posted_at,
           a.code            as treasury,
           a.account_type,
           m.movement_type,
           m.amount,
           m.reference,
           m.memo,
           m.source_type,
           m.source_id,
           m.movement_group_id,
           u.full_name       as posted_by
    from treasury_movements m
    join treasury_accounts a on a.id = m.account_id
    left join users u on u.id = m.posted_by;

-- -----------------------------------------------------------------------------
-- record_export — logs an export to the audit trail (§11.3) and returns the
-- audit row. The caller passes the report type and the filters that were used.
-- -----------------------------------------------------------------------------
create or replace function record_export(p_report_type text, p_filters jsonb default '{}'::jsonb)
returns audit_logs
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_row   audit_logs;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('report.export') then
        raise exception 'Not authorised to export reports' using errcode = '42501';
    end if;

    insert into audit_logs (actor_user_id, action, entity_type, after)
    values (v_actor, 'report.export', 'report',
            jsonb_build_object('report', p_report_type, 'filters', coalesce(p_filters,'{}'::jsonb)))
    returning * into v_row;

    return v_row;
end;
$$;

-- --- Row-Level Security ------------------------------------------------------
alter table loans_granted          enable row level security;
alter table loan_repayments        enable row level security;
alter table company_borrowings     enable row level security;
alter table borrowing_installments enable row level security;

create policy loans_read on loans_granted
    for select using (
        app_has_permission('loan.read')
        or exists (select 1 from requests r where r.id = loans_granted.request_id
                   and r.requester_id = app_current_user_id())
    );

create policy loan_repayments_read on loan_repayments
    for select using (
        app_has_permission('loan.read')
        or exists (select 1 from loans_granted l join requests r on r.id = l.request_id
                   where l.id = loan_repayments.loan_id
                     and r.requester_id = app_current_user_id())
    );

create policy borrowings_read on company_borrowings
    for select using (
        app_has_permission('borrowing.read')
        or entered_by = app_current_user_id()
    );

create policy borrowing_installments_read on borrowing_installments
    for select using (
        app_has_permission('borrowing.read')
        or exists (select 1 from requests r where r.id = borrowing_installments.request_id
                   and r.requester_id = app_current_user_id())
    );

-- --- grants ------------------------------------------------------------------
grant select on loans_granted, loan_repayments, company_borrowings,
                borrowing_installments, loan_summary, borrowing_summary,
                v_transaction_history
to app_user;

grant execute on function create_loan_request(numeric, text, text, text) to app_user;
grant execute on function disburse_loan(uuid, text) to app_user;
grant execute on function add_loan_installment(uuid, numeric, date) to app_user;
grant execute on function record_loan_repayment(uuid, text) to app_user;
grant execute on function enter_borrowing(text, numeric) to app_user;
grant execute on function confirm_borrowing_receipt(uuid, boolean, text, text) to app_user;
grant execute on function request_borrowing_repayment(uuid, numeric, numeric, numeric) to app_user;
grant execute on function pay_borrowing_repayment(uuid, text) to app_user;
grant execute on function record_export(text, jsonb) to app_user;

grant select, insert, update, delete on loans_granted, loan_repayments,
                company_borrowings, borrowing_installments to service_role;
grant usage, select on sequence seq_borrowing_reference to service_role;
grant execute on all functions in schema public to service_role;

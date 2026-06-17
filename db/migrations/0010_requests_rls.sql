-- =============================================================================
-- SEPF Treasury — Milestone 3 (Requests and expenses)
-- Migration 0010: Row-Level Security and grants for the request tables
-- -----------------------------------------------------------------------------
-- Reads: a user always sees their own requests; full readers (request.read.all)
-- see every request. Writes happen exclusively through the SECURITY DEFINER
-- functions in 0009 — app_user gets SELECT + EXECUTE only, never direct DML.
-- =============================================================================

alter table requests            enable row level security;
alter table request_versions    enable row level security;
alter table request_validations enable row level security;
alter table payments            enable row level security;

-- A request is visible to its requester, an internal beneficiary, or a full
-- reader. The child tables inherit visibility from their parent request.
create policy requests_read on requests
    for select using (
        requester_id = app_current_user_id()
        or app_has_permission('request.read.all')
    );

create policy request_versions_read on request_versions
    for select using (
        exists (select 1 from requests r
                where r.id = request_versions.request_id
                  and (r.requester_id = app_current_user_id()
                       or app_has_permission('request.read.all')))
        or beneficiary_user_id = app_current_user_id()
    );

create policy request_validations_read on request_validations
    for select using (
        exists (select 1
                from request_versions v
                join requests r on r.id = v.request_id
                where v.id = request_validations.request_version_id
                  and (r.requester_id = app_current_user_id()
                       or app_has_permission('request.read.all')))
    );

create policy payments_read on payments
    for select using (
        exists (select 1 from requests r
                where r.id = payments.request_id
                  and (r.requester_id = app_current_user_id()
                       or app_has_permission('request.read.all')))
    );

-- --- grants ------------------------------------------------------------------
grant select on requests, request_versions, request_validations, payments,
                request_overview
to app_user;

grant execute on function create_request(numeric, text, text, text, text, uuid, text, text, text, date) to app_user;
grant execute on function create_request_correction(uuid, numeric, text, text, text, text, uuid, text, text, text, date) to app_user;
grant execute on function record_first_validation(uuid, text, text) to app_user;
grant execute on function record_final_validation(uuid, text, text) to app_user;
grant execute on function pay_request(uuid, text) to app_user;
grant execute on function disburse_small_advance(uuid, text) to app_user;
-- apply_validation is internal; intentionally NOT granted to app_user.

-- service_role already holds blanket privileges on objects in this schema
-- (granted in 0007 for existing objects). Re-grant to cover the new objects.
grant select, insert, update, delete on requests, request_versions,
                request_validations, payments to service_role;
grant usage, select on sequence seq_request_reference to service_role;
grant execute on all functions in schema public to service_role;

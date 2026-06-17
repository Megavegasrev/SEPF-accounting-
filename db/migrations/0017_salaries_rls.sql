-- =============================================================================
-- SEPF Treasury — Milestone 5 (Salaries and advances)
-- Migration 0017: Row-Level Security and grants
-- -----------------------------------------------------------------------------
-- A user always sees their own salary data ("My salary" dashboard, §11.2);
-- salary.read sees everyone's. Writes go only through the functions in 0016.
-- =============================================================================

alter table salary_profiles         enable row level security;
alter table salary_cycles           enable row level security;
alter table salary_advance_requests enable row level security;
alter table salary_balance_payments enable row level security;

create policy salary_profiles_read on salary_profiles
    for select using (user_id = app_current_user_id()
                      or app_has_permission('salary.read'));

create policy salary_cycles_read on salary_cycles
    for select using (user_id = app_current_user_id()
                      or app_has_permission('salary.read'));

create policy salary_advance_requests_read on salary_advance_requests
    for select using (user_id = app_current_user_id()
                      or app_has_permission('salary.read')
                      or app_has_permission('request.read.all'));

create policy salary_balance_payments_read on salary_balance_payments
    for select using (
        app_has_permission('salary.read')
        or exists (select 1 from salary_cycles c
                   where c.id = salary_balance_payments.cycle_id
                     and c.user_id = app_current_user_id())
    );

-- --- grants ------------------------------------------------------------------
grant select on salary_profiles, salary_cycles, salary_advance_requests,
                salary_balance_payments, salary_cycle_summary
to app_user;

grant execute on function set_salary_profile(uuid, boolean, numeric, boolean, numeric, date, text) to app_user;
grant execute on function open_salary_cycle(uuid, date) to app_user;
grant execute on function request_salary_advance(date, numeric) to app_user;
grant execute on function pay_salary_advance(uuid, text) to app_user;
grant execute on function pay_salary_balance(uuid, text) to app_user;
grant execute on function salary_advances_paid(uuid) to app_user;
grant execute on function salary_advances_approved_unpaid(uuid) to app_user;
grant execute on function salary_balance_paid(uuid) to app_user;
-- ensure_salary_cycle is internal; intentionally not granted to app_user.

grant select, insert, update, delete on salary_profiles, salary_cycles,
                salary_advance_requests, salary_balance_payments to service_role;
grant execute on all functions in schema public to service_role;

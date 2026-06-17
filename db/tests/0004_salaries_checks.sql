-- =============================================================================
-- SEPF Treasury — Milestone 5 acceptance checks (Salaries and advances)
-- -----------------------------------------------------------------------------
--   for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
--   psql -d sepf -f db/tests/0004_salaries_checks.sql
-- Large treasury starts at 5000000 (demo seed). "EXPECT FAIL" lines must raise.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off
\set fval  '''22222222-2222-2222-2222-222222222222'''
\set super '''11111111-1111-1111-1111-111111111111'''
\set ops   '''33333333-3333-3333-3333-333333333333'''
\set cash  '''44444444-4444-4444-4444-444444444444'''
\set acct  '''55555555-5555-5555-5555-555555555555'''

\echo '\n################ T1  SALARY CONFIGURATION (§8.1) ################'
\echo '-- EXPECT FAIL: a non-Super-Admin cannot configure salaries'
set role app_user; select set_config('app.current_user_id', :acct, false);
select set_salary_profile(:ops, true, 200000, true, 100000, date '2026-06-01', null);
\echo '-- EXPECT FAIL: ceiling greater than salary is rejected (§13.1 rule 6)'
select set_config('app.current_user_id', :super, false);
select set_salary_profile(:ops, true, 100000, true, 150000, date '2026-06-01', null);
\echo '-- OK: Super Admin sets the salary (salary 200000, advance ceiling 100000)'
select (set_salary_profile(:ops, true, 200000, true, 100000, date '2026-06-01','Base')).monthly_salary;
\echo '-- a user with advances disabled, and one with a salary above the treasury'
select (set_salary_profile(:acct, true, 300000, false, 0, date '2026-06-01','No advance')).can_request_advance;
select (set_salary_profile(:cash, true, 9000000, false, 0, date '2026-06-01','Huge')).monthly_salary;
reset role;

\echo '\n################ T2  ADVANCE — ANTI-OVERRUN (§8.2, §17.1) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (request_salary_advance(date '2026-06-10', 60000)).request_id as r1 \gset
reset role;
select id as v1 from request_versions where request_id = :'r1' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'v1','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'v1','approved');
\echo '-- available is now 100000 - 0 paid - 60000 approved = 40000'
\echo '-- EXPECT FAIL: requesting 50000 exceeds the available 40000'
select set_config('app.current_user_id', :ops, false);
select request_salary_advance(date '2026-06-12', 50000);
\echo '-- OK: request 30000 (fits), then approve it'
select (request_salary_advance(date '2026-06-12', 30000)).request_id as r2 \gset
reset role;
select id as v2 from request_versions where request_id = :'r2' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'v2','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'v2','approved');

\echo '-- EXPECT FAIL: a salary advance cannot be paid via pay_request (dedicated fn)'
select set_config('app.current_user_id', :acct, false);
select pay_request(:'r1','wrong-path');
\echo '-- EXPECT FAIL: a non-Accountant cannot pay a salary advance'
select set_config('app.current_user_id', :cash, false);
select pay_salary_advance(:'r1','pay-adv-1');
\echo '-- OK: the Accountant pays both advances from the large treasury'
select set_config('app.current_user_id', :acct, false);
select (pay_salary_advance(:'r1','pay-adv-1')).status as adv1;
select (pay_salary_advance(:'r2','pay-adv-2')).status as adv2;
\echo '-- large treasury: 5000000 - 60000 - 30000 = 4910000'
select balance from treasury_balances where code = 'LARGE';
reset role;
select id as cyc6 from salary_cycles where user_id = :ops and period = date '2026-06-01' \gset
\echo '-- cycle summary: advances_paid=90000, advance_available=10000'
set role app_user; select set_config('app.current_user_id', :acct, false);
select advances_paid, advances_approved_unpaid, advance_available, outstanding_balance
from salary_cycle_summary where cycle_id = :'cyc6';
\echo '-- EXPECT FAIL: requesting 20000 now exceeds the available 10000'
select set_config('app.current_user_id', :ops, false);
select request_salary_advance(date '2026-06-20', 20000);
\echo '-- EXPECT FAIL: a user whose profile forbids advances cannot request one'
select set_config('app.current_user_id', :acct, false);
select request_salary_advance(date '2026-06-10', 10000);
reset role;

\echo '\n################ T3  OUTSTANDING BALANCE & DEBT CARRY-FORWARD (§8.3, §17.1) ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
\echo '-- June outstanding = 200000 salary - 90000 advances = 110000'
select outstanding_balance from salary_cycle_summary where cycle_id = :'cyc6';
reset role;
\echo '-- a new month is opened (July advance request) — June debt must NOT vanish'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (request_salary_advance(date '2026-07-05', 10000)).request_id as r3 \gset
reset role;
set role app_user; select set_config('app.current_user_id', :acct, false);
\echo '-- June still owes 110000 after July is opened'
select outstanding_balance from salary_cycle_summary where cycle_id = :'cyc6';
\echo '-- EXPECT FAIL: the Cashier cannot pay a salary balance'
select set_config('app.current_user_id', :cash, false);
select pay_salary_balance(:'cyc6','pay-bal-6');
\echo '-- OK: the Accountant settles June in full; large 4910000 - 110000 = 4800000'
select set_config('app.current_user_id', :acct, false);
select (pay_salary_balance(:'cyc6','pay-bal-6')).amount as june_balance_paid;
select balance from treasury_balances where code = 'LARGE';
select outstanding_balance from salary_cycle_summary where cycle_id = :'cyc6';
\echo '-- EXPECT FAIL: nothing left to settle for June'
select pay_salary_balance(:'cyc6','pay-bal-6b');
reset role;

\echo '\n################ T4  INSUFFICIENT TREASURY — BALANCE REMAINS DUE (§8.3) ################'
\echo '-- the Cashier has a 9,000,000 salary; the large treasury cannot cover it'
set role app_user; select set_config('app.current_user_id', :acct, false);
select (open_salary_cycle(:cash, date '2026-06-01')).monthly_salary as cashier_salary;
reset role;
select id as cyc_cash from salary_cycles where user_id = :cash and period = date '2026-06-01' \gset
set role app_user; select set_config('app.current_user_id', :acct, false);
\echo '-- EXPECT FAIL: large treasury (4800000) < 9000000 -> nothing paid, remains due'
select pay_salary_balance(:'cyc_cash','pay-bal-cash');
\echo '-- the balance is still fully outstanding (9000000)'
select outstanding_balance from salary_cycle_summary where cycle_id = :'cyc_cash';
reset role;

\echo '\n################ FINAL: large treasury unchanged at 4800000 ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
select balance from treasury_balances where code = 'LARGE';
reset role;
-- =============================================================================
-- SEPF Treasury — Milestone 6 acceptance checks (Investments and capital)
-- -----------------------------------------------------------------------------
--   for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
--   psql -d sepf -f db/tests/0005_investments_capital_checks.sql
-- Large treasury starts at 5000000 (demo seed). "EXPECT FAIL" lines must raise.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off
\set fval  '''22222222-2222-2222-2222-222222222222'''
\set super '''11111111-1111-1111-1111-111111111111'''
\set ops   '''33333333-3333-3333-3333-333333333333'''
\set cash  '''44444444-4444-4444-4444-444444444444'''
\set acct  '''55555555-5555-5555-5555-555555555555'''

\echo '\n################ T1  CAPITAL CONTRIBUTIONS (§9.2) ################'
\echo '-- EXPECT FAIL: a non-shareholder cannot declare a contribution (rule 8)'
set role app_user; select set_config('app.current_user_id', :ops, false);
select declare_capital_contribution(1000000);
\echo '-- OK: each shareholder declares; large treasury stays 5000000 (awaiting)'
select set_config('app.current_user_id', :super, false);
select (declare_capital_contribution(1000000)).id as c1 \gset
select set_config('app.current_user_id', :fval, false);
select (declare_capital_contribution(500000)).id as c2 \gset
select set_config('app.current_user_id', :acct, false);
select balance as large_after_declare from treasury_balances where code = 'LARGE';
\echo '-- EXPECT FAIL: a shareholder cannot confirm (only the Accountant)'
select set_config('app.current_user_id', :super, false);
select confirm_capital_contribution(:'c1', true, 'cap-c1');
\echo '-- EXPECT FAIL: "not confirmed" without a cause'
select set_config('app.current_user_id', :acct, false);
select confirm_capital_contribution(:'c2', false, 'cap-c2');
\echo '-- OK: Accountant confirms c1 -> large 6000000; refuses c2 with a cause'
select (confirm_capital_contribution(:'c1', true, 'cap-c1')).status as c1_status;
select (confirm_capital_contribution(:'c2', false, 'cap-c2', 'Funds never arrived')).status as c2_status;
select balance as large_after_confirm from treasury_balances where code = 'LARGE';
\echo '-- idempotent: confirming c1 again with the same key changes nothing'
select (confirm_capital_contribution(:'c1', true, 'cap-c1')).status as c1_again;
select balance as large_still from treasury_balances where code = 'LARGE';
\echo '-- comparative summary (super confirmed=1000000, validator not_confirmed=500000)'
select shareholder_user_id = :super as is_super, total_confirmed, total_not_confirmed
from shareholder_capital_summary order by total_confirmed desc;
reset role;

\echo '\n################ T2  SEPF INVESTMENTS (§9.1) ################'
\echo '-- EXPECT FAIL: a non-shareholder cannot create an investment'
set role app_user; select set_config('app.current_user_id', :ops, false);
select create_investment(2000000,'AutoCorp','Truck','vehicle', :ops, null, 'Logging');
\echo '-- OK: a shareholder creates it; dual approval follows'
select set_config('app.current_user_id', :super, false);
select (create_investment(2000000,'AutoCorp','Truck','vehicle', :ops, null,'Logging')).request_id as ri \gset
reset role;
select id as vri from request_versions where request_id = :'ri' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'vri','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'vri','approved');
\echo '-- EXPECT FAIL: an investment cannot be paid via pay_request (dedicated fn)'
select set_config('app.current_user_id', :acct, false);
select pay_request(:'ri','wrong-path');
\echo '-- EXPECT FAIL: a non-Accountant cannot pay an investment'
select set_config('app.current_user_id', :cash, false);
select pay_investment(:'ri','pay-inv-1');
\echo '-- OK: the Accountant pays; large 6000000 - 2000000 = 4000000; asset created'
select set_config('app.current_user_id', :acct, false);
select (pay_investment(:'ri','pay-inv-1')).cost as asset_cost \gset
select balance as large_after_invest from treasury_balances where code = 'LARGE';
\echo '-- idempotent: paying again returns the same asset (cost matches)'
select (pay_investment(:'ri','pay-inv-1b')).cost = :'asset_cost' as idempotent_pay;
\echo '-- asset register entry'
select asset_name, asset_category, supplier, cost, custodian from asset_register;
reset role;
\echo '-- the Accountant controls the investment payment (no financial effect, §9.1)'
select id as inv_payment from payments where request_id = :'ri' \gset
set role app_user; select set_config('app.current_user_id', :acct, false);
select (record_accounting_control(:'inv_payment','validated', null, 'Asset received')).decision as control;
select balance as large_unchanged from treasury_balances where code = 'LARGE';
reset role;

\echo '\n################ FINAL: large treasury = 4000000 ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
select small_treasury, large_treasury, total_treasury from treasury_consolidated;
reset role;

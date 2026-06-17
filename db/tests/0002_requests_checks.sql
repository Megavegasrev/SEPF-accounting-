-- =============================================================================
-- SEPF Treasury — Milestone 3 acceptance checks (Requests and expenses)
-- -----------------------------------------------------------------------------
-- Run on a fresh database after migrations + seeds 0001..0004 (which leave the
-- small treasury at 150000 and the large at 5000000 via the demo income):
--
--   for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
--   psql -d sepf -f db/tests/0002_requests_checks.sql
--
-- "EXPECT FAIL" lines must raise; everything else must succeed. PostgreSQL 16.
-- Users: super=1111 validator=2222 ops=3333 cashier=4444 accountant=5555.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off
\set ops   '''33333333-3333-3333-3333-333333333333'''
\set fval  '''22222222-2222-2222-2222-222222222222'''
\set super '''11111111-1111-1111-1111-111111111111'''
\set cash  '''44444444-4444-4444-4444-444444444444'''
\set acct  '''55555555-5555-5555-5555-555555555555'''

\echo '\n################ T1  NORMAL SMALL EXPENSE (§17.1) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(50000,'external','Fuel','operations','small_treasury',null,'Total station')).id as req1 \gset
reset role;
select id as v1 from request_versions where request_id = :'req1' \gset

\echo '-- EXPECT FAIL: final approval before first (§6.2)'
set role app_user; select set_config('app.current_user_id', :super, false);
select record_final_validation(:'v1','approved');

\echo '-- EXPECT FAIL: "not approved" with no comment (§6.2)'
set role app_user; select set_config('app.current_user_id', :fval, false);
select record_first_validation(:'v1','not_approved', null);

\echo '-- EXPECT FAIL: Operations Director cannot give first approval'
set role app_user; select set_config('app.current_user_id', :ops, false);
select record_first_validation(:'v1','approved');

\echo '-- OK: first approval, then final approval'
set role app_user; select set_config('app.current_user_id', :fval, false);
select (record_first_validation(:'v1','approved')).decision as first_decision;
select set_config('app.current_user_id', :super, false);
select (record_final_validation(:'v1','approved')).decision as final_decision;

\echo '-- EXPECT FAIL: Accountant cannot pay a small-treasury request'
select set_config('app.current_user_id', :acct, false);
select pay_request(:'req1','pay-req1');

\echo '-- OK: Cashier pays in full; idempotent replay returns the same payment'
select set_config('app.current_user_id', :cash, false);
select (pay_request(:'req1','pay-req1')).id as payment_id \gset
select (pay_request(:'req1','pay-req1-retry')).id = :'payment_id' as idempotent_same_payment;
reset role;

\echo '-- small treasury expect 100000 (150000 - 50000)'
set role app_user; select set_config('app.current_user_id', :acct, false);
select balance from treasury_balances where code = 'SMALL';
reset role;

\echo '\n################ T2  LARGE EXPENSE (§17.1) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(1000000,'external','Generator','investment','large_treasury',null,'Supplier SARL')).id as req2 \gset
reset role;
select id as v2 from request_versions where request_id = :'req2' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'v2','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'v2','approved');
\echo '-- EXPECT FAIL: Cashier cannot pay a large-treasury request'
select set_config('app.current_user_id', :cash, false);  select pay_request(:'req2','pay-req2');
\echo '-- OK: Accountant pays from the large treasury'
select set_config('app.current_user_id', :acct, false);  select (pay_request(:'req2','pay-req2')).status as pay2_status;
\echo '-- large treasury expect 4000000 (5000000 - 1000000)'
select balance from treasury_balances where code = 'LARGE';
reset role;

\echo '\n################ T3  INSUFFICIENT FUNDS / NO PARTIAL (§6.7, §17.1) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(5000000,'external','Truck','investment','large_treasury',null,'Auto SARL')).id as req3 \gset
reset role;
select id as v3 from request_versions where request_id = :'req3' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'v3','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'v3','approved');
\echo '-- EXPECT FAIL: balance 4000000 < 5000000 -> nothing paid'
select set_config('app.current_user_id', :acct, false);  select pay_request(:'req3','pay-req3');
\echo '-- large treasury unchanged at 4000000; no payment row for req3 (expect 0)'
select balance from treasury_balances where code = 'LARGE';
select count(*) as payments_for_req3 from payments where request_id = :'req3';
reset role;

\echo '\n################ T4  CORRECTION CREATES A NEW VERSION (§6.3) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(20000,'external','Stationery','operations','small_treasury',null,'Shop')).id as req4 \gset
reset role;
select id as v4a from request_versions where request_id = :'req4' \gset
set role app_user;
\echo '-- first level requests a correction (comment mandatory, supplied)'
select set_config('app.current_user_id', :fval, false);
select (record_first_validation(:'v4a','correction_requested','Amount too low, revise')).decision as d;
\echo '-- requester submits a corrected version'
select set_config('app.current_user_id', :ops, false);
select (create_request_correction(:'req4',25000,'external','Stationery','operations','small_treasury',null,'Shop')).id as v4b \gset
reset role;
\echo '-- EXPECT FAIL: the superseded version can no longer be approved'
set role app_user; select set_config('app.current_user_id', :fval, false);
select record_first_validation(:'v4a','approved');
\echo '-- OK: approve the new version through to payment'
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'v4b','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'v4b','approved');
select set_config('app.current_user_id', :cash, false);  select (pay_request(:'req4','pay-req4')).amount as paid_amount;
reset role;
\echo '-- version states: expect v4a superseded, v4b approved; small now 75000'
select version_number, status from request_versions where request_id = :'req4' order by version_number;
set role app_user; select set_config('app.current_user_id', :acct, false);
select balance from treasury_balances where code = 'SMALL';
reset role;

\echo '\n################ T5  SELF-APPROVAL TRANSPARENCY (§4.1) ################'
set role app_user; select set_config('app.current_user_id', :fval, false);
select (create_request(5000,'external','Badge','operations','small_treasury',null,'Print shop')).id as req5 \gset
reset role;
select id as v5 from request_versions where request_id = :'req5' \gset
set role app_user; select set_config('app.current_user_id', :fval, false);
select (record_first_validation(:'v5','approved')).is_self_decision as first_is_self;  -- expect t
reset role;

\echo '\n################ T6  ADVANCE DISBURSEMENT THEN REFUSAL (§6.5) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(30000,'external','Emergency part','operations','small_treasury',null,'Garage')).id as req6 \gset
reset role;
\echo '-- EXPECT FAIL: only the Cashier may disburse an advance'
set role app_user; select set_config('app.current_user_id', :acct, false);
select disburse_small_advance(:'req6','adv-req6');
\echo '-- OK: Cashier disburses before approval; small 75000 -> 45000'
select set_config('app.current_user_id', :cash, false);
select (disburse_small_advance(:'req6','adv-req6')).status as adv_status;
select set_config('app.current_user_id', :acct, false);
select balance from treasury_balances where code = 'SMALL';
\echo '-- first level refuses; a refusal NEVER credits the treasury back (§6.5)'
reset role;
select id as v6 from request_versions where request_id = :'req6' \gset
set role app_user; select set_config('app.current_user_id', :fval, false);
select (record_first_validation(:'v6','not_approved','Not eligible')).decision as refusal;
select set_config('app.current_user_id', :acct, false);
\echo '-- payment marked disbursed_unapproved; small still 45000'
select status from payments where request_id = :'req6';
select balance from treasury_balances where code = 'SMALL';
reset role;
\echo '-- EXPECT FAIL: a disbursed request cannot be corrected'
set role app_user; select set_config('app.current_user_id', :ops, false);
select create_request_correction(:'req6',30000,'external','Emergency part','operations','small_treasury',null,'Garage');
reset role;

\echo '\n################ T7  ADVANCE THEN APPROVAL COMPLETES (§6.5) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(10000,'external','Tape','operations','small_treasury',null,'Shop')).id as req7 \gset
reset role;
select id as v7 from request_versions where request_id = :'req7' \gset
set role app_user;
select set_config('app.current_user_id', :cash, false);
select (disburse_small_advance(:'req7','adv-req7')).status as adv7;  -- small 45000 -> 35000
\echo '-- EXPECT FAIL: correction cannot be requested after an advance (§6.5)'
select set_config('app.current_user_id', :fval, false);
select record_first_validation(:'v7','correction_requested','please revise');
\echo '-- OK: approvals complete the advance; balance unchanged afterwards'
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'v7','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'v7','approved');
select set_config('app.current_user_id', :acct, false);
select status from payments where request_id = :'req7';     -- expect completed
select balance from treasury_balances where code = 'SMALL'; -- expect 35000
reset role;

\echo '\n################ T8  RLS VISIBILITY (§11.1) ################'
\echo '-- Cashier is not the requester and lacks request.read.all: sees 0 of req2'
set role app_user; select set_config('app.current_user_id', :cash, false);
select count(*) as cashier_sees_req2 from requests where id = :'req2';
\echo '-- Accountant has request.read.all: sees req2'
select set_config('app.current_user_id', :acct, false);
select count(*) as accountant_sees_req2 from requests where id = :'req2';
\echo '-- Operations Director sees their own req1'
select set_config('app.current_user_id', :ops, false);
select count(*) as ops_sees_own_req1 from requests where id = :'req1';
reset role;

\echo '\n################ FINAL LEDGER STATE ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
select small_treasury, large_treasury, total_treasury from treasury_consolidated;  -- 35000 / 4000000 / 4035000
select status, count(*) from payments group by status order by status;
reset role;

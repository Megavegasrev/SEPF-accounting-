-- =============================================================================
-- SEPF Treasury — Milestone 4 acceptance checks (Controls and transfers)
-- -----------------------------------------------------------------------------
--   for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
--   psql -d sepf -f db/tests/0003_controls_transfers_checks.sql
-- Start state (from the demo seed): small=150000, large=5000000, transit=0.
-- "EXPECT FAIL" lines must raise. The two setup payments spend 15000 from
-- the small treasury, so the consolidated total is 5135000 and must stay constant.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off
\set ops   '''33333333-3333-3333-3333-333333333333'''
\set fval  '''22222222-2222-2222-2222-222222222222'''
\set super '''11111111-1111-1111-1111-111111111111'''
\set cash  '''44444444-4444-4444-4444-444444444444'''
\set acct  '''55555555-5555-5555-5555-555555555555'''

\echo '\n################ SETUP: an approved & paid small expense to control ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(10000,'external','Repair','operations','small_treasury',null,'Garage')).id as rc \gset
reset role;
select id as vc from request_versions where request_id = :'rc' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'vc','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'vc','approved');
select set_config('app.current_user_id', :cash, false);  select (pay_request(:'rc','pay-rc')).status;
reset role;
select id as pc from payments where request_id = :'rc' \gset

\echo '\n################ T1  ACCOUNTING CONTROL HAS NO FINANCIAL EFFECT (§7.2, §17.1) ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
\echo '-- small balance before control (expect 140000)'
select balance from treasury_balances where code = 'SMALL';
\echo '-- EXPECT FAIL: "not validated" without a cause (§17.1)'
select record_accounting_control(:'pc','not_validated', null, 'no cause given');
\echo '-- OK: "not validated" WITH a cause; treasury is NOT credited back'
select (record_accounting_control(:'pc','not_validated','Missing invoice','please attach')).decision;
\echo '-- small balance after control (still 140000)'
select balance from treasury_balances where code = 'SMALL';
\echo '-- EXPECT FAIL: a non-Accountant cannot control'
select set_config('app.current_user_id', :cash, false);
select record_accounting_control(:'pc','validated', null, null);
reset role;

\echo '\n################ T2  INTERNAL RECEIPT — NO SECOND MOVEMENT (§7.4) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(5000,'internal','Per diem','salary','small_treasury', :ops ,null)).id as ri \gset
reset role;
select id as vi from request_versions where request_id = :'ri' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'vi','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'vi','approved');
select set_config('app.current_user_id', :cash, false);  select (pay_request(:'ri','pay-ri')).status;
reset role;
select id as pi from payments where request_id = :'ri' \gset
\echo '-- EXPECT FAIL: a non-beneficiary cannot confirm receipt'
set role app_user; select set_config('app.current_user_id', :cash, false);
select confirm_internal_receipt(:'pi','received', null);
\echo '-- OK: the beneficiary acknowledges; small unchanged at 135000'
select set_config('app.current_user_id', :ops, false);
select (confirm_internal_receipt(:'pi','received','Thanks')).status;
select set_config('app.current_user_id', :acct, false);
select balance from treasury_balances where code = 'SMALL';
reset role;

\echo '\n################ T3  TRANSFER — CONSOLIDATED TOTAL CONSTANT (§10.3, §17.1) ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
\echo '-- before: small=135000 large=5000000 transit=0 total=5135000'
select small_treasury, large_treasury, funds_in_transit, total_treasury from treasury_consolidated;
\echo '-- EXPECT FAIL: the Accountant cannot INITIATE a small->large transfer'
select initiate_transfer('small_to_large', 40000, 'trf-1');
\echo '-- OK: the Cashier sends; small -40000, transit +40000, TOTAL UNCHANGED'
select set_config('app.current_user_id', :cash, false);
select (initiate_transfer('small_to_large', 40000, 'trf-1')).reference as trf1_ref \gset
select set_config('app.current_user_id', :acct, false);
select small_treasury, large_treasury, funds_in_transit, total_treasury from treasury_consolidated;
\echo '-- idempotent: same key returns the same transfer (no double send)'
set role app_user; select set_config('app.current_user_id', :cash, false);
select (initiate_transfer('small_to_large', 40000, 'trf-1')).reference = :'trf1_ref' as idempotent_send;
reset role;
select id as t1 from internal_transfers where reference = :'trf1_ref' \gset
\echo '-- EXPECT FAIL: the Cashier cannot CONFIRM a small->large transfer'
set role app_user; select set_config('app.current_user_id', :cash, false);
select confirm_transfer(:'t1');
\echo '-- OK: the Accountant confirms; transit -40000, large +40000, TOTAL UNCHANGED'
select set_config('app.current_user_id', :acct, false);
select (confirm_transfer(:'t1')).status as t1_status;
select small_treasury, large_treasury, funds_in_transit, total_treasury from treasury_consolidated;
\echo '-- idempotent: confirming again is a no-op'
select (confirm_transfer(:'t1')).status as t1_status_again;
\echo '-- EXPECT FAIL: insufficient balance to send'
set role app_user; select set_config('app.current_user_id', :cash, false);
select initiate_transfer('small_to_large', 999999999, 'trf-toobig');
reset role;

\echo '\n################ T4  TRANSFER CANCEL SAFEGUARD (proposed) ################'
set role app_user; select set_config('app.current_user_id', :cash, false);
select (initiate_transfer('small_to_large', 20000, 'trf-2')).reference as trf2_ref \gset
reset role;
select id as t2 from internal_transfers where reference = :'trf2_ref' \gset
\echo '-- after send: small=75000 transit=20000 total=5135000'
set role app_user; select set_config('app.current_user_id', :acct, false);
select small_treasury, funds_in_transit, total_treasury from treasury_consolidated;
\echo '-- EXPECT FAIL: only the initiator may cancel'
select cancel_transfer(:'t2','changed my mind');
\echo '-- OK: the initiator cancels; funds return to source, total unchanged'
select set_config('app.current_user_id', :cash, false);
select (cancel_transfer(:'t2','duplicate entry')).status as t2_status;
select set_config('app.current_user_id', :acct, false);
select small_treasury, funds_in_transit, total_treasury from treasury_consolidated;
\echo '-- EXPECT FAIL: a cancelled transfer cannot be confirmed'
select set_config('app.current_user_id', :acct, false);
select confirm_transfer(:'t2');
reset role;

\echo '\n################ T5  ATTACHMENT REUSE DETECTION (§7.1) ################'
set role app_user; select set_config('app.current_user_id', :cash, false);
select (add_attachment('payment', :'pc', 'receipt1.jpg','image/jpeg', 1024,'k/1','HASH_X')).is_potential_duplicate as first_dup;
select (add_attachment('payment', :'pi', 'receipt2.jpg','image/jpeg', 2048,'k/2','HASH_X')).is_potential_duplicate as second_dup;
reset role;

\echo '\n################ FINAL LEDGER STATE (total must still be 5135000) ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
select small_treasury, large_treasury, funds_in_transit, total_treasury from treasury_consolidated;
select status, count(*) from internal_transfers group by status order by status;
reset role;

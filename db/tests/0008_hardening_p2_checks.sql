-- =============================================================================
-- SEPF Treasury — Priority 2 hardening checks (identity & cross-table integrity)
--   psql -d sepf -f db/tests/0008_hardening_p2_checks.sql
-- "EXPECT FAIL" lines must raise. Bad rows are inserted directly (superuser) to
-- exercise the constraints/triggers; valid setup goes through the functions.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off
\set super '''11111111-1111-1111-1111-111111111111'''
\set fval  '''22222222-2222-2222-2222-222222222222'''
\set ops   '''33333333-3333-3333-3333-333333333333'''
\set cash  '''44444444-4444-4444-4444-444444444444'''

reset role;
select id as small_id from treasury_accounts where code='SMALL' \gset
select id as large_id from treasury_accounts where code='LARGE' \gset
select id as transit_id from treasury_accounts where code='TRANSIT' \gset

\echo '\n################ SETUP: two expense requests; pay the first ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_request(10000,'external','A','operations','small_treasury',null,'X')).id as req1 \gset
select (create_request(20000,'external','B','operations','small_treasury',null,'Y')).id as req2 \gset
reset role;
select id as v1 from request_versions where request_id = :'req1' \gset
select id as v2 from request_versions where request_id = :'req2' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'v1','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'v1','approved');
select set_config('app.current_user_id', :cash, false);  select (pay_request(:'req1','pay-p2')).status;
reset role;
select id as pay1 from payments where request_id = :'req1' \gset

\echo '\n################ T1  payment version must belong to its request ################'
\echo '-- EXPECT FAIL: point the payment at another request''s version'
update payments set request_version_id = :'v2' where id = :'pay1';

\echo '\n################ T2  request-type guards ################'
\echo '-- EXPECT FAIL: investment referencing an expense request'
insert into investments (request_id, supplier, asset_name, asset_category, created_by)
values (:'req2', 'S', 'Asset', 'vehicle', :super);
\echo '-- EXPECT FAIL: loan referencing an expense request'
insert into loans_granted (request_id, borrower_name, principal, created_by)
values (:'req2', 'Borrower', 1000, :super);

\echo '\n################ T3  transfer direction must match account types ################'
\echo '-- EXPECT FAIL: small_to_large with source = LARGE account'
insert into internal_transfers (idempotency_key, direction, amount, source_account_id,
    destination_account_id, transit_account_id, initiated_by)
values ('bad-dir-1', 'small_to_large', 1000, :'large_id', :'small_id', :'transit_id', :cash);

\echo '\n################ T4  transfer status coherence ################'
set role app_user; select set_config('app.current_user_id', :cash, false);
select (initiate_transfer('small_to_large', 5000, 'p2-trf')).id as t1 \gset
reset role;
\echo '-- EXPECT FAIL: mark confirmed without an actor/timestamp'
update internal_transfers set status = 'confirmed' where id = :'t1';

\echo '\n################ T5  shareholder identity (capital) ################'
\echo '-- EXPECT FAIL: capital contribution for a non-shareholder (Operations Director)'
insert into capital_contributions (shareholder_user_id, amount, declared_by)
values (:ops, 1000, :ops);
\echo '-- EXPECT FAIL: contribution not declared by the shareholder themselves'
insert into capital_contributions (shareholder_user_id, amount, declared_by)
values (:super, 1000, :fval);
\echo '-- OK: a shareholder declares via the function (identity from shareholders table)'
set role app_user; select set_config('app.current_user_id', :super, false);
select (declare_capital_contribution(1000)).status as declared;
\echo '-- EXPECT FAIL: Operations Director (not a shareholder) declares'
select set_config('app.current_user_id', :ops, false);
select declare_capital_contribution(1000);
reset role;

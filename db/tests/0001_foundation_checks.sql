-- =============================================================================
-- SEPF Treasury — Foundation milestone acceptance checks
-- -----------------------------------------------------------------------------
-- Exercises the foundation against the spec's integrity rules. Run AFTER the
-- migrations and all three seed files (including 0003 demo movements) on a
-- throwaway database:
--
--   for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
--   psql -d sepf -f db/tests/0001_foundation_checks.sql
--
-- Lines marked "EXPECT FAIL" must raise an ERROR; everything else must succeed
-- with the stated values. Tested on PostgreSQL 16.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off

reset role;
select id as small_id  from treasury_accounts where code='SMALL' \gset
select id as large_id  from treasury_accounts where code='LARGE' \gset
select id as small_mov from treasury_movements where idempotency_key='demo-income-small-1' \gset
select id as large_mov from treasury_movements where idempotency_key='demo-income-large-1' \gset

\echo '\n== T1  idempotency: expect total_movements = 2 =='
select count(*) as total_movements from treasury_movements;

\echo '\n== T2  derived balances (Accountant): expect small=150000 large=5000000 total=5150000 =='
set role app_user;
select set_config('app.current_user_id','55555555-5555-5555-5555-555555555555', false);
select small_treasury, large_treasury, funds_in_transit, total_treasury from treasury_consolidated;
reset role;

\echo '\n== T3  RLS: Cashier sees only small+transit (expect 1 visible movement) =='
set role app_user;
select set_config('app.current_user_id','44444444-4444-4444-4444-444444444444', false);
select count(*) as movements_visible_to_cashier from treasury_movements;
reset role;

\echo '\n== T4  EXPECT FAIL: Cashier records into LARGE treasury =='
set role app_user;
select set_config('app.current_user_id','44444444-4444-4444-4444-444444444444', false);
select record_income(:'large_id', 100, 'cashier-into-large', 'should fail');
reset role;

\echo '\n== T5  EXPECT FAIL: zero-amount income =='
set role app_user;
select set_config('app.current_user_id','44444444-4444-4444-4444-444444444444', false);
select record_income(:'small_id', 0, 'zero-amount', 'should fail');
reset role;

\echo '\n== T6  EXPECT FAIL (x2): the ledger is immutable (UPDATE, DELETE) =='
update treasury_movements set amount = 1 where id = :'small_mov';
delete from treasury_movements where id = :'small_mov';

\echo '\n== T7  EXPECT FAIL: Cashier attempts a reversal =='
set role app_user;
select set_config('app.current_user_id','44444444-4444-4444-4444-444444444444', false);
select reverse_movement(:'small_mov', 'nope', 'rev-by-cashier');
reset role;

\echo '\n== T8  EXPECT FAIL: reversal with empty reason =='
set role app_user;
select set_config('app.current_user_id','11111111-1111-1111-1111-111111111111', false);
select reverse_movement(:'large_mov', '   ', 'rev-empty-reason');

\echo '\n== T9  OK: Super Admin reverses the large income =='
select (reverse_movement(:'large_mov', 'Correcting an erroneous entry', 'rev-large-ok')).reference as reversal_reference;
\echo '\n== T9b idempotent replay returns the SAME reference =='
select (reverse_movement(:'large_mov', 'Correcting an erroneous entry', 'rev-large-ok')).reference as replay_reference;
reset role;

\echo '\n== T10 EXPECT FAIL: a movement cannot be reversed twice =='
set role app_user;
select set_config('app.current_user_id','11111111-1111-1111-1111-111111111111', false);
select reverse_movement(:'large_mov', 'again', 'rev-large-twice');
reset role;

\echo '\n== T11 balances after reversal (Accountant): expect large=0 total=150000, 3 movements =='
set role app_user;
select set_config('app.current_user_id','55555555-5555-5555-5555-555555555555', false);
select small_treasury, large_treasury, total_treasury from treasury_consolidated;
select count(*) as total_movements from treasury_movements;
reset role;

\echo '\n== T12 audit trail: expect income.record=2, movement.reverse=1 =='
select action, count(*) from audit_logs group by action order by action;

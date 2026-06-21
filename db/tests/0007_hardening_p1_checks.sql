-- =============================================================================
-- SEPF Treasury — Priority 1 hardening checks (income, treasury, scheduling)
--   for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
--   psql -d sepf -f db/tests/0007_hardening_p1_checks.sql
-- Demo start: small=150000, large=5000000. "EXPECT FAIL" lines must raise.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off
\set ops   '''33333333-3333-3333-3333-333333333333'''
\set cash  '''44444444-4444-4444-4444-444444444444'''
\set acct  '''55555555-5555-5555-5555-555555555555'''
reset role;
select id as small_id from treasury_accounts where code='SMALL' \gset
select id as large_id from treasury_accounts where code='LARGE' \gset

\echo '\n################ T1  STRUCTURED INCOME — atomic, idempotent, separated ################'
set role app_user; select set_config('app.current_user_id', :cash, false);
select (record_income(:'small_id', 7000, 'inc-p1-1',
        'Client Mabiala', 'vente', 'Vente de bois', current_date, 'especes', 'REC-001', null)).movement_id as inc_mov \gset
\echo '-- a positive income movement exists (expect 7000)'
select amount from treasury_movements where id = :'inc_mov';
\echo '-- small balance increased to 157000'
select set_config('app.current_user_id', :acct, false);
select balance from treasury_balances where code = 'SMALL';
\echo '-- idempotent: same key creates no second entry/movement (counts stay 1 income movement here)'
set role app_user; select set_config('app.current_user_id', :cash, false);
select (record_income(:'small_id', 7000, 'inc-p1-1',
        'Client Mabiala','vente','retry', current_date,'especes','REC-001', null)).movement_id = :'inc_mov' as same_entry;
select set_config('app.current_user_id', :acct, false);
select balance as small_still_157000 from treasury_balances where code = 'SMALL';
select count(*) as income_entries_count from income_entries;
\echo '-- EXPECT FAIL: Operations Director cannot record income'
select set_config('app.current_user_id', :ops, false);
select record_income(:'small_id', 1000, 'inc-ops', null,null,null,current_date,null,null,null);
\echo '-- EXPECT FAIL: Cashier cannot record into the large treasury'
select set_config('app.current_user_id', :cash, false);
select record_income(:'large_id', 1000, 'inc-cash-large', null,null,null,current_date,null,null,null);
\echo '-- OK: Accountant records large income (5000000 -> 5009000)'
select set_config('app.current_user_id', :acct, false);
select (record_income(:'large_id', 9000, 'inc-p1-2', 'Subvention',null,null,current_date,'virement',null,null)).amount as large_income;
select balance from treasury_balances where code = 'LARGE';
\echo '-- income is separated: no capital/loan/borrowing/transfer rows created (expect 0/0/0/0)'
select (select count(*) from capital_contributions) as cap,
       (select count(*) from loans_granted) as loans,
       (select count(*) from company_borrowings) as borrow,
       (select count(*) from internal_transfers) as transfers;
reset role;

\echo '\n################ T2  TREASURY ACCOUNT PROTECTION (used account) ################'
\echo '-- EXPECT FAIL: change opening_balance of a used account'
update treasury_accounts set opening_balance = 999 where code = 'SMALL';
\echo '-- EXPECT FAIL: change account_type of a used account'
update treasury_accounts set account_type = 'large_treasury' where code = 'SMALL';
\echo '-- EXPECT FAIL: change currency of a used account'
update treasury_accounts set currency = 'EUR' where code = 'SMALL';
\echo '-- EXPECT FAIL: delete a used account'
delete from treasury_accounts where code = 'SMALL';
\echo '-- OK: renaming a used account is allowed'
update treasury_accounts set name = 'Petite caisse' where code = 'SMALL';
select name from treasury_accounts where code = 'SMALL';

\echo '\n################ T3  LOAN INSTALLMENT DUE DATE MANDATORY ################'
\echo '-- EXPECT FAIL: scheduling a loan installment without a due date'
set role app_user; select set_config('app.current_user_id', :acct, false);
select add_loan_installment(gen_random_uuid(), 1000, null);
reset role;

\echo '\n################ T4  BORROWING REPAYMENT SCHEDULE ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
select (enter_borrowing('Banque Atlantique', 100000)).id as bor \gset
select (confirm_borrowing_receipt(:'bor', true, 'rcv-p1')).status as bor_status;
\echo '-- one overdue and one upcoming scheduled repayment request'
select (request_borrowing_repayment(:'bor', 50000, 5000, 1000, 1, current_date - 1)).id as inst_overdue \gset
select (request_borrowing_repayment(:'bor', 20000, 2000, 0, 2, current_date + 30)).id as inst_upcoming \gset
select installment_number, schedule_state from borrowing_installment_schedule
where borrowing_id = :'bor' order by installment_number;
reset role;

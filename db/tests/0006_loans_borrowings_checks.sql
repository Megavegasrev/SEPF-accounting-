-- =============================================================================
-- SEPF Treasury — Milestone 7 acceptance checks (Loans, borrowings, reports)
-- -----------------------------------------------------------------------------
--   for f in db/migrations/*.sql db/seed/*.sql; do psql -d sepf -f "$f"; done
--   psql -d sepf -f db/tests/0006_loans_borrowings_checks.sql
-- Large treasury starts at 5000000 (demo seed). "EXPECT FAIL" lines must raise.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off
\set fval  '''22222222-2222-2222-2222-222222222222'''
\set super '''11111111-1111-1111-1111-111111111111'''
\set ops   '''33333333-3333-3333-3333-333333333333'''
\set cash  '''44444444-4444-4444-4444-444444444444'''
\set acct  '''55555555-5555-5555-5555-555555555555'''

\echo '\n################ T1  LOAN GRANTED — RECEIVABLE (§10.1) ################'
set role app_user; select set_config('app.current_user_id', :ops, false);
select (create_loan_request(1000000,'M. Diallo','Equipment loan')).request_id as rl \gset
reset role;
select id as vrl from request_versions where request_id = :'rl' \gset
select id as loan1 from loans_granted where request_id = :'rl' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'vrl','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'vrl','approved');
\echo '-- EXPECT FAIL: a non-Accountant cannot disburse a loan'
select set_config('app.current_user_id', :cash, false);
select disburse_loan(:'rl','dis-loan-1');
\echo '-- OK: the Accountant disburses; large 5000000 - 1000000 = 4000000'
select set_config('app.current_user_id', :acct, false);
select (disburse_loan(:'rl','dis-loan-1')).status as loan_status;
select balance as large_after_disburse from treasury_balances where code = 'LARGE';
select outstanding_receivable from loan_summary where loan_id = :'loan1';
\echo '-- schedule two instalments (400000 + 600000 = principal); due dates mandatory'
select (add_loan_installment(:'loan1', 400000, current_date + 30)).id as inst1 \gset
\echo '-- EXPECT FAIL: scheduling beyond the principal'
select add_loan_installment(:'loan1', 700000, current_date + 30);
select (add_loan_installment(:'loan1', 600000, current_date + 60)).id as inst2 \gset
\echo '-- record both repayments; large returns to 5000000, receivable 0'
select (record_loan_repayment(:'inst1','rep-1')).status as r1;
select (record_loan_repayment(:'inst2','rep-2')).status as r2;
select balance as large_after_repaid from treasury_balances where code = 'LARGE';
select outstanding_receivable from loan_summary where loan_id = :'loan1';
\echo '-- idempotent: re-recording inst1 changes nothing'
select (record_loan_repayment(:'inst1','rep-1-again')).status as r1_again;
select balance as large_still from treasury_balances where code = 'LARGE';
reset role;

\echo '\n################ T2  BORROWING — LIABILITY (§10.2) ################'
\echo '-- EXPECT FAIL: a non-finance role cannot enter a borrowing'
set role app_user; select set_config('app.current_user_id', :ops, false);
select enter_borrowing('BGFI Bank', 2000000);
\echo '-- OK: the Accountant enters it; large unchanged until receipt confirmed'
select set_config('app.current_user_id', :acct, false);
select (enter_borrowing('BGFI Bank', 2000000)).id as bor1 \gset
select balance as large_after_enter from treasury_balances where code = 'LARGE';
\echo '-- EXPECT FAIL: a non-Accountant cannot confirm receipt'
select set_config('app.current_user_id', :ops, false);
select confirm_borrowing_receipt(:'bor1', true, 'rcv-bor-1');
\echo '-- OK: the Accountant confirms; large 5000000 + 2000000 = 7000000'
select set_config('app.current_user_id', :acct, false);
select (confirm_borrowing_receipt(:'bor1', true, 'rcv-bor-1')).status as bor_status;
select balance as large_after_receipt from treasury_balances where code = 'LARGE';
select outstanding_liability from borrowing_summary where borrowing_id = :'bor1';
\echo '-- EXPECT FAIL: a repayment whose principal exceeds the liability'
select request_borrowing_repayment(:'bor1', 3000000, 0, 0);
\echo '-- OK: request a repayment split principal/interest/charges (500000/50000/10000)'
select (request_borrowing_repayment(:'bor1', 500000, 50000, 10000)).request_id as rb \gset
reset role;
select id as vrb from request_versions where request_id = :'rb' \gset
set role app_user;
select set_config('app.current_user_id', :fval, false);  select record_first_validation(:'vrb','approved');
select set_config('app.current_user_id', :super, false); select record_final_validation(:'vrb','approved');
\echo '-- EXPECT FAIL: cannot pay a borrowing repayment via pay_request'
select set_config('app.current_user_id', :acct, false);
select pay_request(:'rb','wrong-path');
\echo '-- EXPECT FAIL: a non-Accountant cannot pay the repayment'
select set_config('app.current_user_id', :cash, false);
select pay_borrowing_repayment(:'rb','pay-bor-rep-1');
\echo '-- OK: the Accountant pays 560000; large 7000000 - 560000 = 6440000'
select set_config('app.current_user_id', :acct, false);
select (pay_borrowing_repayment(:'rb','pay-bor-rep-1')).status as rep_status;
select balance as large_after_repay from treasury_balances where code = 'LARGE';
select principal_repaid, interest_paid, charges_paid, outstanding_liability
from borrowing_summary where borrowing_id = :'bor1';
reset role;

\echo '\n################ T3  REPORTS & EXPORT AUDIT (§11) ################'
\echo '-- EXPECT FAIL: a role without report.export cannot export'
set role app_user; select set_config('app.current_user_id', :cash, false);
select record_export('treasury', '{"period":"2026-06"}');
\echo '-- OK: the Accountant exports; it is logged to the audit trail'
select set_config('app.current_user_id', :acct, false);
select (record_export('treasury', '{"period":"2026-06"}')).action as exported;
select count(*) > 0 as export_audited from audit_logs where action = 'report.export';
\echo '-- transaction history is readable by a full ledger reader'
select count(*) > 0 as history_visible from v_transaction_history;
reset role;

\echo '\n################ FINAL: large treasury = 6440000 ################'
set role app_user; select set_config('app.current_user_id', :acct, false);
select large_treasury, total_treasury from treasury_consolidated;
reset role;

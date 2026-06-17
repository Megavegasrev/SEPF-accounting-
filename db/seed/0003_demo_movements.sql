-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Seed 0003: OPTIONAL demo movements
-- -----------------------------------------------------------------------------
-- Demonstrates the foundation acceptance criterion ("balances are calculated")
-- by posting income through the transactional functions exactly as the backend
-- would: each posting runs under a specific acting user via SET LOCAL.
-- Run this only in demo/test environments, never in production.
-- =============================================================================

begin;

-- Cashier records small-treasury income.
set local app.current_user_id = '44444444-4444-4444-4444-444444444444';
select record_income(
    (select id from treasury_accounts where code = 'SMALL'),
    150000, 'demo-income-small-1', 'Initial cash float'
);

-- Accountant records large-treasury income.
set local app.current_user_id = '55555555-5555-5555-5555-555555555555';
select record_income(
    (select id from treasury_accounts where code = 'LARGE'),
    5000000, 'demo-income-large-1', 'Confirmed capital contribution receipt'
);

-- Idempotency check: re-posting the same key must NOT create a duplicate.
set local app.current_user_id = '44444444-4444-4444-4444-444444444444';
select record_income(
    (select id from treasury_accounts where code = 'SMALL'),
    150000, 'demo-income-small-1', 'Initial cash float (retry)'
);

commit;

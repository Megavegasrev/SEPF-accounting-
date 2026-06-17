-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Seed 0002: The five user accounts, the three treasuries, base settings
-- -----------------------------------------------------------------------------
-- Fulfils §15.1 "procedure for creating the five accounts" and the demo dataset.
-- SECURITY: password_hash is the locked sentinel '!', which cannot match any
-- password (same convention as /etc/shadow). Real credentials are set per
-- environment by the bootstrap step (see docs/ARCHITECTURE.md), and every
-- account starts with must_change_password = true. No real e-mail domains are
-- used (.test), per §15.2 "do not use real data in public demonstrations".
-- Fixed UUIDs are used so the optional demo movements can reference the actors.
-- =============================================================================

insert into users (id, email, full_name, role_id, password_hash, must_change_password, created_by)
select v.id, v.email, v.full_name, r.id, '!', true, null
from (values
    ('11111111-1111-1111-1111-111111111111'::uuid, 'superadmin@sepf.test',  'Super Administrator',  'super_admin'),
    ('22222222-2222-2222-2222-222222222222'::uuid, 'validator@sepf.test',   'First-Level Validator','first_validator'),
    ('33333333-3333-3333-3333-333333333333'::uuid, 'operations@sepf.test',  'Operations Director',  'operations_director'),
    ('44444444-4444-4444-4444-444444444444'::uuid, 'cashier@sepf.test',     'Cashier',              'cashier'),
    ('55555555-5555-5555-5555-555555555555'::uuid, 'accountant@sepf.test',  'Accountant',           'accountant')
) as v(id, email, full_name, role_code)
join roles r on r.code = v.role_code
on conflict (id) do nothing;

-- The three treasuries (§5). One small, one large, one funds-in-transit.
insert into treasury_accounts (account_type, code, name, opening_balance, responsible_user_id)
values
    ('small_treasury',   'SMALL',   'Small Treasury',  0,
        '44444444-4444-4444-4444-444444444444'),  -- Cashier
    ('large_treasury',   'LARGE',   'Large Treasury',  0,
        '55555555-5555-5555-5555-555555555555'),  -- Accountant
    ('funds_in_transit', 'TRANSIT', 'Funds in Transit', 0, null)
on conflict (account_type) do nothing;

-- Base settings. advance_disbursement_ceiling_fcfa addresses the control gap
-- flagged in the spec review: the Cashier's "already disbursed" path (§6.5) has
-- no ceiling in the spec. 0 = disabled (no limit) until SEPF sets a value.
insert into settings (key, value, description) values
    ('session_ttl_minutes',
     '60'::jsonb,
     'Session lifetime in minutes (§14.2 expiring sessions).'),
    ('advance_disbursement_ceiling_fcfa',
     '0'::jsonb,
     'Per-transaction ceiling for the Cashier pre-approval disbursement (§6.5). 0 = no limit. RECOMMEND setting a value.')
on conflict (key) do nothing;

-- =============================================================================
-- SEPF Treasury — Milestone 3 (Requests and expenses)
-- Seed 0004: Permissions and grants for the request workflow
-- -----------------------------------------------------------------------------
-- Extends the §4.2 matrix with the request/approval/payment capabilities.
-- Idempotent: safe to re-run.
-- =============================================================================

insert into permissions (code, domain, description) values
    ('request.create',           'requests', 'Create an expense request (§4.2: all roles).'),
    ('request.read.all',         'requests', 'Read every request, version and decision.'),
    ('request.approve.first',    'requests', 'Give first-level approval (First-Level Validator).'),
    ('request.approve.final',    'requests', 'Give final approval (Super Administrator).'),
    ('expense.pay.small',        'requests', 'Pay an approved request from the small treasury.'),
    ('expense.pay.large',        'requests', 'Pay an approved request from the large treasury.'),
    ('expense.disburse_advance', 'requests', 'Disburse a small expense before approval (§6.5).')
on conflict (code) do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id
from (values
    -- Every role may create a request (§4.2 "Create an expense request": Yes x5)
    ('super_admin',         'request.create'),
    ('first_validator',     'request.create'),
    ('operations_director', 'request.create'),
    ('cashier',             'request.create'),
    ('accountant',          'request.create'),
    -- Full read of the request file (§11.1) + the Accountant who processes/pays
    ('super_admin',         'request.read.all'),
    ('first_validator',     'request.read.all'),
    ('accountant',          'request.read.all'),
    -- Approvals (§4.1 / §6.2)
    ('first_validator',     'request.approve.first'),
    ('super_admin',         'request.approve.final'),
    -- Payments by treasury owner (§6.4/§6.6)
    ('cashier',             'expense.pay.small'),
    ('accountant',          'expense.pay.large'),
    -- Advance disbursement is reserved for the Cashier + small treasury (§6.5)
    ('cashier',             'expense.disburse_advance')
) as grant_map(role_code, perm_code)
join roles r       on r.code = grant_map.role_code
join permissions p on p.code = grant_map.perm_code
on conflict do nothing;

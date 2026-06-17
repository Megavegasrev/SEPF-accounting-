-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Seed 0001: Roles, permissions and the role/permission matrix (FOUNDATION)
-- -----------------------------------------------------------------------------
-- This encodes the foundation-relevant slice of the §4.2 permission matrix.
-- NOTE (flagged in the spec review): §4.2 uses values such as Read / Control /
-- Monitor / Limited that are not defined, and omits several sensitive actions
-- (notably who may create a reversal/adjustment, §13.2). Pending SEPF's written
-- clarification (§19.1), reversal authority is granted to the Super Administrator
-- only, and the audit trail (§11.1) to the Super Administrator + First-Level
-- Validator. Later milestones will extend this matrix.
-- =============================================================================

-- --- Roles (§4) --------------------------------------------------------------
insert into roles (code, name, description) values
    ('super_admin',         'Super Administrator',  'Shareholder No. 1, final approver, supervision.'),
    ('first_validator',     'First-Level Validator','Shareholder No. 2, first approver, full consultation.'),
    ('operations_director', 'Operations Director',  'Creates and tracks operational requests.'),
    ('cashier',             'Cashier',              'Small treasury: routine income, small expenses, transfers.'),
    ('accountant',          'Accountant',           'Large treasury: payments, salaries, controls, transfers.')
on conflict (code) do nothing;

-- --- Permissions (atomic capabilities used in the foundation) -----------------
insert into permissions (code, domain, description) values
    ('rbac.manage',         'rbac',     'Create/modify roles, permissions and grants.'),
    ('users.read',          'users',    'View user accounts and sessions.'),
    ('users.manage',        'users',    'Create, edit and suspend user accounts.'),
    ('ledger.read.full',    'ledger',   'Read all treasury accounts and movements.'),
    ('ledger.read.small',   'ledger',   'Read the small treasury and funds in transit only.'),
    ('income.record.small', 'ledger',   'Record income into the small treasury.'),
    ('income.record.large', 'ledger',   'Record income into the large treasury.'),
    ('movement.reverse',    'ledger',   'Create a reversal/adjustment of a posted movement.'),
    ('treasury.configure',  'treasury', 'Create/configure treasury accounts.'),
    ('settings.manage',     'settings', 'Edit application settings.'),
    ('audit.read',          'audit',    'Read the audit trail.')
on conflict (code) do nothing;

-- --- Role/permission grants (foundation subset) ------------------------------
-- Helper insert: maps a role code to a permission code.
insert into role_permissions (role_id, permission_id)
select r.id, p.id
from (values
    -- Super Administrator
    ('super_admin',         'rbac.manage'),
    ('super_admin',         'users.read'),
    ('super_admin',         'users.manage'),
    ('super_admin',         'ledger.read.full'),
    ('super_admin',         'movement.reverse'),
    ('super_admin',         'treasury.configure'),
    ('super_admin',         'settings.manage'),
    ('super_admin',         'audit.read'),
    -- First-Level Validator (full read incl. audit trail, §11.1)
    ('first_validator',     'users.read'),
    ('first_validator',     'ledger.read.full'),
    ('first_validator',     'audit.read'),
    -- Operations Director: no ledger-wide rights in the foundation (his data are
    -- his own requests, introduced in a later milestone).
    -- Cashier: small treasury
    ('cashier',             'income.record.small'),
    ('cashier',             'ledger.read.small'),
    -- Accountant: large treasury + full ledger read (§4.2 "view history = Yes")
    ('accountant',          'income.record.large'),
    ('accountant',          'ledger.read.full')
) as grant_map(role_code, perm_code)
join roles r       on r.code = grant_map.role_code
join permissions p on p.code = grant_map.perm_code
on conflict do nothing;

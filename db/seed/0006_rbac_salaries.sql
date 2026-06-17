-- =============================================================================
-- SEPF Treasury — Milestone 5 (Salaries and advances)
-- Seed 0006: Permissions and grants for salaries
-- Idempotent: safe to re-run.
-- =============================================================================

insert into permissions (code, domain, description) values
    ('salary.configure', 'salary', 'Configure each user''s salary rights (§8.1).'),
    ('salary.read',      'salary', 'View salary profiles, cycles and balances.'),
    ('salary.pay',       'salary', 'Pay salary advances and outstanding balances (§8.2/§8.3).')
on conflict (code) do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id
from (values
    -- §4.2 "Configure salaries": Super Admin = Yes
    ('super_admin',     'salary.configure'),
    -- §4.2: First-Level Validator = Read, Accountant = Monitor; Super Admin too
    ('super_admin',     'salary.read'),
    ('first_validator', 'salary.read'),
    ('accountant',      'salary.read'),
    -- §8.2/§8.3 payment by the Accountant from the large treasury
    ('accountant',      'salary.pay')
) as grant_map(role_code, perm_code)
join roles r       on r.code = grant_map.role_code
join permissions p on p.code = grant_map.perm_code
on conflict do nothing;

-- Note: the right to *request* an advance is governed per-user by the salary
-- profile flag can_request_advance (§8.1), not by a role permission — every user
-- already holds request.create.

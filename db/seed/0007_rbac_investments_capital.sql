-- =============================================================================
-- SEPF Treasury — Milestone 6 (Investments and capital contributions)
-- Seed 0007: Permissions and grants. Idempotent: safe to re-run.
-- =============================================================================

insert into permissions (code, domain, description) values
    ('investment.create', 'investment', 'Create an SEPF investment (shareholders only, §9.1).'),
    ('investment.pay',    'investment', 'Pay an approved investment from the large treasury (§9.1).'),
    ('investment.read',   'investment', 'View investments and the asset register.'),
    ('capital.contribute','capital',    'Declare one''s own capital contribution (§9.2, rule 8).'),
    ('capital.confirm',   'capital',    'Confirm receipt of a capital contribution (§9.2).'),
    ('capital.read',      'capital',    'View capital contributions and the comparative summary.')
on conflict (code) do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id
from (values
    -- §9.1 investments: only the two shareholders create; Accountant pays
    ('super_admin',     'investment.create'),
    ('first_validator', 'investment.create'),
    ('accountant',      'investment.pay'),
    ('super_admin',     'investment.read'),
    ('first_validator', 'investment.read'),
    ('accountant',      'investment.read'),
    -- §9.2 / §13.1 rule 8: only the two shareholders contribute; Accountant confirms
    ('super_admin',     'capital.contribute'),
    ('first_validator', 'capital.contribute'),
    ('accountant',      'capital.confirm'),
    ('super_admin',     'capital.read'),
    ('first_validator', 'capital.read'),
    ('accountant',      'capital.read')
) as grant_map(role_code, perm_code)
join roles r       on r.code = grant_map.role_code
join permissions p on p.code = grant_map.perm_code
on conflict do nothing;

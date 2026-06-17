-- =============================================================================
-- SEPF Treasury — Milestone 7 (Loans, borrowings and reports)
-- Seed 0008: Permissions and grants. Idempotent: safe to re-run.
-- =============================================================================

insert into permissions (code, domain, description) values
    ('loan.disburse',     'loan',      'Disburse an approved loan from the large treasury (§10.1).'),
    ('loan.manage',       'loan',      'Schedule and record loan repayments (§10.1).'),
    ('loan.read',         'loan',      'View loans and the receivables summary.'),
    ('borrowing.enter',   'borrowing', 'Enter a new borrowing administratively (§10.2).'),
    ('borrowing.confirm', 'borrowing', 'Confirm receipt of a borrowing (§10.2).'),
    ('borrowing.repay',   'borrowing', 'Pay an approved borrowing repayment (§10.2).'),
    ('borrowing.read',    'borrowing', 'View borrowings and the liabilities summary.'),
    ('report.export',     'report',    'Export reports (logged to the audit trail, §11.3).')
on conflict (code) do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id
from (values
    -- §10.1 loans: Accountant disburses & manages repayments; full readers view
    ('accountant',      'loan.disburse'),
    ('accountant',      'loan.manage'),
    ('super_admin',     'loan.read'),
    ('first_validator', 'loan.read'),
    ('accountant',      'loan.read'),
    -- §10.2 borrowings: entered by the three finance roles; Accountant confirms/pays
    ('super_admin',     'borrowing.enter'),
    ('first_validator', 'borrowing.enter'),
    ('accountant',      'borrowing.enter'),
    ('accountant',      'borrowing.confirm'),
    ('accountant',      'borrowing.repay'),
    ('super_admin',     'borrowing.read'),
    ('first_validator', 'borrowing.read'),
    ('accountant',      'borrowing.read'),
    -- §11.3 exports: the two full readers + the Accountant
    ('super_admin',     'report.export'),
    ('first_validator', 'report.export'),
    ('accountant',      'report.export')
) as grant_map(role_code, perm_code)
join roles r       on r.code = grant_map.role_code
join permissions p on p.code = grant_map.perm_code
on conflict do nothing;

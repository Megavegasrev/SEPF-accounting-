-- =============================================================================
-- SEPF Treasury — Milestone 4 (Controls and transfers)
-- Seed 0005: Permissions and grants for controls, documents and transfers
-- Idempotent: safe to re-run.
-- =============================================================================

insert into permissions (code, domain, description) values
    ('accounting.control',                'control',  'Record the Accountant''s accounting control (§7.2).'),
    ('attachment.add',                    'control',  'Attach or replace supporting documents (§7.1).'),
    ('receipt.confirm',                   'control',  'An internal beneficiary acknowledges receipt (§7.4).'),
    ('transfer.read',                     'transfer', 'View internal transfers.'),
    ('transfer.initiate.small_to_large',  'transfer', 'Cashier sends from small to large treasury (§10.3).'),
    ('transfer.initiate.large_to_small',  'transfer', 'Accountant sends from large to small treasury (§10.3).'),
    ('transfer.confirm.small_to_large',   'transfer', 'Accountant confirms a small->large transfer (§10.3).'),
    ('transfer.confirm.large_to_small',   'transfer', 'Cashier confirms a large->small transfer (§10.3).'),
    ('transfer.cancel',                   'transfer', 'Cancel a still-pending transfer (proposed safeguard).')
on conflict (code) do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id
from (values
    -- Accounting control (§7.2)
    ('accountant',      'accounting.control'),
    -- Supporting documents: anyone who creates a request or records an expense
    ('super_admin',     'attachment.add'),
    ('first_validator', 'attachment.add'),
    ('operations_director','attachment.add'),
    ('cashier',         'attachment.add'),
    ('accountant',      'attachment.add'),
    -- Internal receipt acknowledgement: any user may be a beneficiary (§7.4)
    ('super_admin',     'receipt.confirm'),
    ('first_validator', 'receipt.confirm'),
    ('operations_director','receipt.confirm'),
    ('cashier',         'receipt.confirm'),
    ('accountant',      'receipt.confirm'),
    -- Transfer visibility: the two operators + the two full readers (§11.1)
    ('super_admin',     'transfer.read'),
    ('first_validator', 'transfer.read'),
    ('cashier',         'transfer.read'),
    ('accountant',      'transfer.read'),
    -- Transfer workflow (§10.3): initiator/confirmer by direction
    ('cashier',         'transfer.initiate.small_to_large'),
    ('accountant',      'transfer.confirm.small_to_large'),
    ('accountant',      'transfer.initiate.large_to_small'),
    ('cashier',         'transfer.confirm.large_to_small'),
    -- Cancel safeguard available to both operators (the function also restricts
    -- it to the initiator of the specific transfer)
    ('cashier',         'transfer.cancel'),
    ('accountant',      'transfer.cancel')
) as grant_map(role_code, perm_code)
join roles r       on r.code = grant_map.role_code
join permissions p on p.code = grant_map.perm_code
on conflict do nothing;

-- =============================================================================
-- SEPF Treasury — Seed 0009: shareholders (Priority 2.5)
-- The two SEPF shareholders. Identity is now explicit and independent of the
-- application role; seeded from the current capital-eligible roles. Idempotent.
-- =============================================================================
insert into shareholders (user_id, created_by)
select u.id, null
from users u join roles r on r.id = u.role_id
where r.code in ('super_admin', 'first_validator')
on conflict (user_id) do nothing;

-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Migration 0004: Audit trail and application settings
-- -----------------------------------------------------------------------------
-- Spec references:
--   §2.1  Traceability: every creation, approval, payment, control and
--         correction is timestamped and attributed to a user.
--   §13   Support objects: audit_logs, settings.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- audit_logs — append-only trail. before/after snapshots are stored as JSONB so
-- any entity can be audited without a dedicated column layout.
-- -----------------------------------------------------------------------------
create table audit_logs (
    id            uuid primary key default gen_random_uuid(),
    actor_user_id uuid references users(id),   -- NULL = system action
    action        text not null,               -- e.g. movement.post, user.suspend
    entity_type   text not null,               -- e.g. treasury_movement, user
    entity_id     uuid,
    before        jsonb,
    after         jsonb,
    ip            inet,
    request_id    text,                        -- correlate with backend logs
    created_at    timestamptz not null default now()
);

create index idx_audit_entity on audit_logs(entity_type, entity_id);
create index idx_audit_actor on audit_logs(actor_user_id, created_at desc);
create index idx_audit_created on audit_logs(created_at desc);

create trigger trg_audit_immutable
    before update or delete on audit_logs
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- settings — key/value configuration (JSONB). Seeded with the parameters the
-- foundation already needs and the control thresholds flagged during the spec
-- review (e.g. the Cashier advance-disbursement ceiling, currently unbounded
-- in the spec — see docs/ARCHITECTURE.md "Open decisions").
-- -----------------------------------------------------------------------------
create table settings (
    key         text primary key,
    value       jsonb not null,
    description text,
    updated_by  uuid references users(id),
    updated_at  timestamptz not null default now()
);

create trigger trg_settings_updated_at
    before update on settings
    for each row execute function set_updated_at();

-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Migration 0007: Database connection roles and privilege grants
-- -----------------------------------------------------------------------------
-- Two least-privilege roles back the application (no superuser in the app):
--   * app_user     — RLS-bound role for ordinary business requests. Cannot write
--                    the ledger directly; must call the transactional functions.
--   * service_role — trusted role (BYPASSRLS) for authentication, session
--                    issuance and one-off administrative bootstrap.
-- Login passwords are NOT set here; they are configured per environment at
-- deploy time (e.g. ALTER ROLE app_user WITH LOGIN PASSWORD '...').
-- =============================================================================

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'app_user') then
        create role app_user nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role nologin bypassrls;
    end if;
end
$$;

grant usage on schema public to app_user, service_role;

-- --- app_user: least privilege, RLS does the gating --------------------------
-- Reads
grant select on
    roles, permissions, role_permissions, users, sessions, login_events,
    treasury_accounts, treasury_movements, audit_logs, settings,
    treasury_balances, treasury_consolidated
to app_user;

-- Administrative writes that are themselves RLS-gated (rbac.manage / users.manage
-- / settings.manage). The ledger is intentionally absent — see functions below.
grant insert, update on roles, permissions, role_permissions to app_user;
grant insert, update on users to app_user;
grant insert, update on settings to app_user;
grant insert        on login_events to app_user;  -- logout events
grant update        on sessions to app_user;       -- self-revoke (logout)

-- Business-facing transactional functions only. post_treasury_movement is the
-- internal engine and is deliberately NOT granted to app_user, so the role can
-- never post an arbitrary, untyped movement.
grant execute on function record_income(uuid, numeric, text, text, uuid) to app_user;
grant execute on function reverse_movement(uuid, text, text) to app_user;
grant execute on function app_has_permission(text) to app_user, service_role;
grant execute on function app_current_user_id() to app_user, service_role;

-- --- service_role: trusted auth / bootstrap path -----------------------------
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

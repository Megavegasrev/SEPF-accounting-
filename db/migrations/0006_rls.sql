-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Migration 0006: Row-Level Security policies
-- -----------------------------------------------------------------------------
-- Defence in depth (§14.2 "Permissions checked on the server AND in the
-- database"). Two backend connection roles are assumed (created in 0007):
--   * app_user     — normal business requests; bound by the policies below.
--                    The backend sets `SET LOCAL app.current_user_id = '<uuid>'`
--                    on every transaction.
--   * service_role — trusted auth/bootstrap path; BYPASSRLS.
-- SECURITY DEFINER financial functions are owned by the migration superuser and
-- therefore bypass RLS for writes, which is why treasury_movements below has
-- read-only policies for app_user.
-- Once RLS is enabled, access is default-deny unless a policy grants it.
-- =============================================================================

alter table roles            enable row level security;
alter table permissions      enable row level security;
alter table role_permissions enable row level security;
alter table users            enable row level security;
alter table sessions         enable row level security;
alter table login_events     enable row level security;
alter table treasury_accounts  enable row level security;
alter table treasury_movements enable row level security;
alter table audit_logs       enable row level security;
alter table settings         enable row level security;

-- --- roles / permissions / role_permissions ---------------------------------
-- Any authenticated user may read the catalogues; only rbac.manage may change.
create policy roles_read on roles
    for select using (app_current_user_id() is not null);
create policy roles_write on roles
    for all using (app_has_permission('rbac.manage'))
            with check (app_has_permission('rbac.manage'));

create policy permissions_read on permissions
    for select using (app_current_user_id() is not null);
create policy permissions_write on permissions
    for all using (app_has_permission('rbac.manage'))
            with check (app_has_permission('rbac.manage'));

create policy role_permissions_read on role_permissions
    for select using (app_current_user_id() is not null);
create policy role_permissions_write on role_permissions
    for all using (app_has_permission('rbac.manage'))
            with check (app_has_permission('rbac.manage'));

-- --- users ------------------------------------------------------------------
create policy users_read on users
    for select using (id = app_current_user_id()
                      or app_has_permission('users.read'));
create policy users_insert on users
    for insert with check (app_has_permission('users.manage'));
create policy users_update on users
    for update using (app_has_permission('users.manage'))
            with check (app_has_permission('users.manage'));
-- No delete policy: accounts are suspended, never deleted (§14.2).

-- --- sessions ---------------------------------------------------------------
-- A user sees and may revoke (update) their own sessions; creation is performed
-- by the trusted auth path (service_role). users.read may inspect any session.
create policy sessions_read on sessions
    for select using (user_id = app_current_user_id()
                      or app_has_permission('users.read'));
create policy sessions_revoke on sessions
    for update using (user_id = app_current_user_id())
            with check (user_id = app_current_user_id());

-- --- login_events -----------------------------------------------------------
-- Inserts must work even pre-authentication (failed logins), hence check(true).
create policy login_events_insert on login_events
    for insert with check (true);
create policy login_events_read on login_events
    for select using (user_id = app_current_user_id()
                      or app_has_permission('audit.read'));

-- --- treasury_accounts ------------------------------------------------------
-- Full-ledger readers see every account; a small-treasury reader (Cashier) sees
-- only the small and funds-in-transit accounts; the responsible user always sees
-- their own account. Mirrors the §4.2 "view history" column.
create policy treasury_accounts_read on treasury_accounts
    for select using (
        app_has_permission('ledger.read.full')
        or responsible_user_id = app_current_user_id()
        or (app_has_permission('ledger.read.small')
            and account_type in ('small_treasury', 'funds_in_transit'))
    );
create policy treasury_accounts_write on treasury_accounts
    for all using (app_has_permission('treasury.configure'))
            with check (app_has_permission('treasury.configure'));

-- --- treasury_movements -----------------------------------------------------
-- Read-only for app_user; all writes go through SECURITY DEFINER functions.
create policy movements_read on treasury_movements
    for select using (
        app_has_permission('ledger.read.full')
        or (app_has_permission('ledger.read.small')
            and account_id in (
                select id from treasury_accounts
                where account_type in ('small_treasury', 'funds_in_transit')))
    );

-- --- audit_logs -------------------------------------------------------------
-- Readable by audit.read; written only by definer functions / service_role.
create policy audit_read on audit_logs
    for select using (app_has_permission('audit.read'));

-- --- settings ---------------------------------------------------------------
create policy settings_read on settings
    for select using (app_current_user_id() is not null);
create policy settings_write on settings
    for all using (app_has_permission('settings.manage'))
            with check (app_has_permission('settings.manage'));

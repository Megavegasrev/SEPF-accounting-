-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Migration 0002: Users, roles, permissions, sessions, login history
-- -----------------------------------------------------------------------------
-- Spec references:
--   §4   Users, roles and permissions (five fixed roles, no public sign-up)
--   §13  Data model: users/profiles, roles, permissions, role_permissions,
--        sessions/logins
--   §14.2 Security: no public registration, expiring sessions, login history,
--        immediate account suspension.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- roles — the five business roles from §4. Fixed set, seeded separately.
-- -----------------------------------------------------------------------------
create table roles (
    id          uuid primary key default gen_random_uuid(),
    code        text not null unique
                    check (code ~ '^[a-z_]+$'),
    name        text not null,
    description text,
    created_at  timestamptz not null default now()
);

comment on table roles is 'Fixed business roles (§4). Not user-creatable in v1.';

-- -----------------------------------------------------------------------------
-- permissions — one row per atomic, server-enforced capability.
-- The §4.2 matrix is modelled as discrete permission codes rather than a
-- Yes/No/Read/Control/Monitor scale, because that scale is not yet defined in
-- the spec (flagged for SEPF clarification). Each "cell" becomes a permission.
-- -----------------------------------------------------------------------------
create table permissions (
    id          uuid primary key default gen_random_uuid(),
    code        text not null unique
                    check (code ~ '^[a-z_]+(\.[a-z_]+)+$'),  -- e.g. income.record
    domain      text not null,                               -- grouping for UI
    description text not null,
    created_at  timestamptz not null default now()
);

comment on table permissions is
    'Atomic capabilities. Checked on the server AND in the database (§14.2).';

-- -----------------------------------------------------------------------------
-- role_permissions — which role is granted which permission.
-- -----------------------------------------------------------------------------
create table role_permissions (
    role_id       uuid not null references roles(id) on delete cascade,
    permission_id uuid not null references permissions(id) on delete cascade,
    granted_at    timestamptz not null default now(),
    primary key (role_id, permission_id)
);

-- -----------------------------------------------------------------------------
-- users — the five identified people. One business role per user.
-- Salary eligibility (§8.1) is deliberately NOT here: it is independent from the
-- application role and belongs to a later milestone (salary_profiles).
-- Authentication is provider-agnostic:
--   * app-managed   -> password_hash is populated (argon2/bcrypt by the backend)
--   * external (e.g. Supabase Auth) -> auth_user_id links to the provider; the
--     password_hash stays NULL.
-- -----------------------------------------------------------------------------
create table users (
    id                   uuid primary key default gen_random_uuid(),
    email                citext not null unique,
    full_name            text not null,
    role_id              uuid not null references roles(id),
    status               text not null default 'active'
                             check (status in ('active', 'suspended')),
    password_hash        text,
    auth_user_id         uuid unique,         -- optional external auth provider id
    must_change_password boolean not null default true,
    last_login_at        timestamptz,
    created_by           uuid references users(id),  -- NULL only for the bootstrap admin
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now(),
    -- Every account must be authenticable one way or the other.
    constraint chk_auth_method
        check (password_hash is not null or auth_user_id is not null)
);

comment on column users.status is
    'suspended blocks all access immediately (§14.2 account suspension).';

create index idx_users_role on users(role_id);

create trigger trg_users_updated_at
    before update on users
    for each row execute function set_updated_at();

-- -----------------------------------------------------------------------------
-- sessions — server-side, expiring sessions (§14.2). The raw token never leaves
-- the backend; only its hash is stored so a DB leak does not yield live tokens.
-- -----------------------------------------------------------------------------
create table sessions (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references users(id) on delete cascade,
    token_hash  text not null unique,
    issued_at   timestamptz not null default now(),
    expires_at  timestamptz not null,
    revoked_at  timestamptz,
    ip          inet,
    user_agent  text,
    constraint chk_session_window check (expires_at > issued_at)
);

create index idx_sessions_user on sessions(user_id);
create index idx_sessions_expiry on sessions(expires_at);

-- -----------------------------------------------------------------------------
-- login_events — append-only login history (§14.2). Failed attempts may have no
-- user_id (unknown e-mail), so email_attempted is captured for forensics.
-- -----------------------------------------------------------------------------
create table login_events (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid references users(id) on delete set null,
    email_attempted citext,
    event           text not null
                        check (event in ('login_success', 'login_failure',
                                         'logout', 'session_expired',
                                         'account_locked')),
    ip              inet,
    user_agent      text,
    created_at      timestamptz not null default now()
);

create index idx_login_events_user on login_events(user_id, created_at desc);

create trigger trg_login_events_immutable
    before update or delete on login_events
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- app_has_permission — the authority check used by RLS policies and by every
-- SECURITY DEFINER financial function. Depends on the tables above, hence
-- defined here rather than in 0001.
-- -----------------------------------------------------------------------------
create or replace function app_has_permission(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from users u
        join role_permissions rp on rp.role_id = u.role_id
        join permissions p       on p.id = rp.permission_id
        where u.id = app_current_user_id()
          and u.status = 'active'
          and p.code = p_code
    );
$$;

comment on function app_has_permission(text) is
    'TRUE when the current app user (active) holds the given permission.';

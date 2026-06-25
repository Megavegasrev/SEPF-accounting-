-- =============================================================================
-- SEPF Treasury — Production hardening (forward-only)
-- Migration 0030 (Priority 3): database security
--   8. session revocation functions (drop broad UPDATE on sessions)
--   9. restrict login_events insertion to the trusted path
--  10. audited SECURITY DEFINER admin functions; drop direct write policies on
--      users/roles/permissions/role_permissions/settings/treasury_accounts
--  11. REVOKE EXECUTE FROM PUBLIC on our functions (extension funcs kept public)
-- =============================================================================

-- --- 8. Sessions: revoke broad UPDATE; constrained revocation functions ------
drop policy if exists sessions_revoke on sessions;
revoke update on sessions from app_user;

create or replace function revoke_session(p_token_hash text)
returns void language plpgsql security definer set search_path = public as $$
begin
    update sessions set revoked_at = now()
    where token_hash = p_token_hash and revoked_at is null;
end;
$$;

create or replace function revoke_user_sessions(p_user_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
    if app_current_user_id() is not null and not app_has_permission('users.manage') then
        raise exception 'Not authorised to revoke sessions' using errcode = '42501';
    end if;
    update sessions set revoked_at = now() where user_id = p_user_id and revoked_at is null;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

-- --- 9. login_events: only the trusted path (service_role) may insert ---------
drop policy if exists login_events_insert on login_events;
revoke insert on login_events from app_user;

-- --- 10. Audited admin functions; drop direct write policies -----------------
drop policy if exists users_insert on users;
drop policy if exists users_update on users;
drop policy if exists roles_write on roles;
drop policy if exists permissions_write on permissions;
drop policy if exists role_permissions_write on role_permissions;
drop policy if exists settings_write on settings;
drop policy if exists treasury_accounts_write on treasury_accounts;
revoke insert, update on users, roles, permissions, role_permissions, settings from app_user;

create or replace function admin_create_user(
    p_email citext, p_full_name text, p_role_code text, p_password_hash text default null
)
returns users language plpgsql security definer set search_path = public as $$
declare v_actor uuid := app_current_user_id(); v_role uuid; v_row users;
begin
    if not app_has_permission('users.manage') then
        raise exception 'Not authorised to manage users' using errcode = '42501';
    end if;
    select id into v_role from roles where code = p_role_code;
    if v_role is null then raise exception 'Unknown role %', p_role_code using errcode = '23503'; end if;
    insert into users (email, full_name, role_id, password_hash, created_by)
    values (p_email, p_full_name, v_role, p_password_hash, v_actor) returning * into v_row;
    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'user.create', 'user', v_row.id, to_jsonb(v_row));
    return v_row;
end;
$$;

create or replace function admin_set_user_status(p_user_id uuid, p_status text)
returns users language plpgsql security definer set search_path = public as $$
declare v_actor uuid := app_current_user_id(); v_row users;
begin
    if not app_has_permission('users.manage') then
        raise exception 'Not authorised to manage users' using errcode = '42501';
    end if;
    if p_status not in ('active','suspended') then
        raise exception 'Invalid user status %', p_status using errcode = '23514';
    end if;
    update users set status = p_status where id = p_user_id returning * into v_row;
    if not found then raise exception 'Unknown user %', p_user_id using errcode = '23503'; end if;
    if p_status = 'suspended' then perform revoke_user_sessions(p_user_id); end if;
    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'user.status', 'user', p_user_id, to_jsonb(v_row));
    return v_row;
end;
$$;

create or replace function admin_set_user_role(p_user_id uuid, p_role_code text)
returns users language plpgsql security definer set search_path = public as $$
declare v_actor uuid := app_current_user_id(); v_role uuid; v_row users;
begin
    if not app_has_permission('users.manage') then
        raise exception 'Not authorised to manage users' using errcode = '42501';
    end if;
    select id into v_role from roles where code = p_role_code;
    if v_role is null then raise exception 'Unknown role %', p_role_code using errcode = '23503'; end if;
    update users set role_id = v_role where id = p_user_id returning * into v_row;
    if not found then raise exception 'Unknown user %', p_user_id using errcode = '23503'; end if;
    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'user.role', 'user', p_user_id, to_jsonb(v_row));
    return v_row;
end;
$$;

create or replace function admin_set_setting(p_key text, p_value jsonb, p_description text default null)
returns settings language plpgsql security definer set search_path = public as $$
declare v_actor uuid := app_current_user_id(); v_row settings;
begin
    if not app_has_permission('settings.manage') then
        raise exception 'Not authorised to manage settings' using errcode = '42501';
    end if;
    insert into settings (key, value, description, updated_by)
    values (p_key, p_value, p_description, v_actor)
    on conflict (key) do update set value = excluded.value,
        description = coalesce(excluded.description, settings.description), updated_by = v_actor
    returning * into v_row;
    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'setting.update', 'setting', null, to_jsonb(v_row));
    return v_row;
end;
$$;

create or replace function admin_set_role_permission(p_role_code text, p_permission_code text, p_grant boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor uuid := app_current_user_id(); v_role uuid; v_perm uuid;
begin
    if not app_has_permission('rbac.manage') then
        raise exception 'Not authorised to manage permissions' using errcode = '42501';
    end if;
    select id into v_role from roles where code = p_role_code;
    select id into v_perm from permissions where code = p_permission_code;
    if v_role is null or v_perm is null then
        raise exception 'Unknown role or permission' using errcode = '23503';
    end if;
    if p_grant then
        insert into role_permissions (role_id, permission_id) values (v_role, v_perm) on conflict do nothing;
    else
        delete from role_permissions where role_id = v_role and permission_id = v_perm;
    end if;
    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, case when p_grant then 'role_permission.grant' else 'role_permission.revoke' end,
            'role_permission', v_role, jsonb_build_object('role', p_role_code, 'permission', p_permission_code));
end;
$$;

create or replace function admin_update_treasury_account(
    p_account_id uuid, p_name text, p_responsible_user_id uuid, p_is_active boolean
)
returns treasury_accounts language plpgsql security definer set search_path = public as $$
declare v_actor uuid := app_current_user_id(); v_row treasury_accounts;
begin
    if not app_has_permission('treasury.configure') then
        raise exception 'Not authorised to configure treasury accounts' using errcode = '42501';
    end if;
    -- opening_balance / account_type / currency stay frozen (guard trigger).
    update treasury_accounts
    set name = coalesce(p_name, name),
        responsible_user_id = p_responsible_user_id,
        is_active = coalesce(p_is_active, is_active)
    where id = p_account_id returning * into v_row;
    if not found then raise exception 'Unknown treasury account %', p_account_id using errcode = '23503'; end if;
    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'treasury.update', 'treasury_account', p_account_id, to_jsonb(v_row));
    return v_row;
end;
$$;

-- --- 11. Lock down EXECUTE: revoke from PUBLIC, keep extension funcs public ---
revoke execute on all functions in schema public from public;

-- Re-grant EXECUTE on extension-owned functions (citext, pgcrypto) to PUBLIC so
-- ordinary type operators (e.g. citext comparison) keep working for all roles.
do $$
declare r record;
begin
    for r in
        select p.oid::regprocedure as fn
        from pg_proc p
        join pg_depend d on d.objid = p.oid and d.deptype = 'e'
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
    loop
        execute format('grant execute on function %s to public', r.fn);
    end loop;
end;
$$;

-- service_role (trusted path) may execute everything; app_user keeps only the
-- explicit grants from earlier migrations plus the admin/session functions below.
grant execute on all functions in schema public to service_role;
grant execute on function revoke_session(text) to app_user, service_role;
grant execute on function revoke_user_sessions(uuid) to app_user, service_role;
grant execute on function admin_create_user(citext, text, text, text) to app_user;
grant execute on function admin_set_user_status(uuid, text) to app_user;
grant execute on function admin_set_user_role(uuid, text) to app_user;
grant execute on function admin_set_setting(text, jsonb, text) to app_user;
grant execute on function admin_set_role_permission(text, text, boolean) to app_user;
grant execute on function admin_update_treasury_account(uuid, text, uuid, boolean) to app_user;

-- =============================================================================
-- SEPF Treasury — Production hardening (forward-only)
-- Migration 0028 (Priority 2.5): separate shareholder identity from app roles
-- -----------------------------------------------------------------------------
-- Shareholder identity now lives in its own protected table, decoupled from the
-- application role. Capital contributions reference active shareholders (not the
-- super_admin/first_validator roles), and a contribution must be the
-- shareholder's own (declared_by = shareholder_user_id).
-- =============================================================================

create table shareholders (
    user_id    uuid primary key references users(id),
    is_active  boolean not null default true,
    note       text,
    created_by uuid references users(id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create trigger trg_shareholders_updated_at
    before update on shareholders
    for each row execute function set_updated_at();

alter table shareholders enable row level security;
create policy shareholders_read on shareholders
    for select using (
        user_id = app_current_user_id()
        or app_has_permission('capital.read')
        or app_has_permission('users.read')
    );
grant select on shareholders to app_user;
grant select, insert, update, delete on shareholders to service_role;

-- A contribution must be the shareholder's own.
alter table capital_contributions
    add constraint chk_capital_self check (declared_by = shareholder_user_id);

-- Identity check now reads the shareholders table (not the role).
create or replace function trg_capital_shareholder_check()
returns trigger language plpgsql as $$
begin
    if not exists (select 1 from shareholders s
                   where s.user_id = new.shareholder_user_id and s.is_active) then
        raise exception 'Capital contributions accept only active shareholders (§9.2)'
            using errcode = '23514';
    end if;
    return new;
end;
$$;

-- declare_capital_contribution: gate by shareholder identity, not by role.
create or replace function declare_capital_contribution(p_amount numeric)
returns capital_contributions
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_row   capital_contributions;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not exists (select 1 from shareholders where user_id = v_actor and is_active) then
        raise exception 'Only a shareholder may declare a capital contribution (§9.2)'
            using errcode = '42501';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Contribution amount must be a positive integer' using errcode = '23514';
    end if;

    insert into capital_contributions (shareholder_user_id, amount, declared_by)
    values (v_actor, p_amount, v_actor)
    returning * into v_row;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'capital.declare', 'capital_contribution', v_row.id, to_jsonb(v_row));

    return v_row;
end;
$$;

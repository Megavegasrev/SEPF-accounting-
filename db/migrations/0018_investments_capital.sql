-- =============================================================================
-- SEPF Treasury — Milestone 6 (Investments and capital contributions)
-- Migration 0018: investments, assets, capital_contributions
-- -----------------------------------------------------------------------------
-- Spec references:
--   §9.1  SEPF investments: only the Super Administrator and First-Level
--         Validator may create one; dual approval; paid by the Accountant; the
--         large treasury decreases; an asset record is created; the investment
--         is linked to its request and approved version (§13.1 rule 11)
--   §9.2  capital contributions: only the two shareholders declare their OWN
--         contribution (§13.1 rule 8); it does NOT follow the request workflow;
--         the large treasury stays unchanged until the Accountant confirms full
--         receipt (a cause is mandatory if not confirmed); on confirmation the
--         large treasury increases; separate per-shareholder histories +
--         comparative summary; a contribution has no loan/advance/repayment
--         fields (§13.1 rule 9)
-- =============================================================================

-- Investments flow through the generic request workflow.
alter table requests drop constraint requests_request_type_check;
alter table requests add constraint requests_request_type_check
    check (request_type in ('expense','salary_advance','investment'));

-- -----------------------------------------------------------------------------
-- investments — the descriptive intent, linked 1:1 to a request (§9.1).
-- -----------------------------------------------------------------------------
create table investments (
    id                uuid primary key default gen_random_uuid(),
    request_id        uuid not null unique references requests(id),
    supplier          text not null,
    asset_name        text not null,
    asset_category    text not null,   -- vehicle, machine, building, equipment …
    custodian_user_id uuid references users(id),
    custodian_name    text,
    created_by        uuid not null references users(id),
    created_at        timestamptz not null default now()
);

create trigger trg_investments_immutable
    before update or delete on investments
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- assets — the asset register entry, materialised when the Accountant pays the
-- investment (§9.1 "Payment -> Asset record"). cost = the amount actually paid.
-- -----------------------------------------------------------------------------
create table assets (
    id                uuid primary key default gen_random_uuid(),
    investment_id     uuid not null unique references investments(id),
    cost              numeric(18,0) not null check (cost > 0),
    acquired_on       date not null,
    custodian_user_id uuid references users(id),
    custodian_name    text,
    payment_id        uuid not null references payments(id),
    movement_id       uuid not null references treasury_movements(id),
    created_by        uuid not null references users(id),
    created_at        timestamptz not null default now()
);

create trigger trg_assets_immutable
    before update or delete on assets
    for each row execute function trg_block_modification();

create view asset_register
with (security_invoker = true) as
    select a.id              as asset_id,
           i.asset_name,
           i.asset_category,
           i.supplier,
           a.cost,
           a.acquired_on,
           coalesce(u.full_name, a.custodian_name) as custodian,
           a.payment_id,
           i.request_id
    from assets a
    join investments i on i.id = a.investment_id
    left join users u on u.id = a.custodian_user_id;

-- -----------------------------------------------------------------------------
-- capital_contributions — declared by a shareholder, confirmed by the Accountant
-- (§9.2). Deliberately NO loan/advance/repayment columns (§13.1 rule 9).
-- -----------------------------------------------------------------------------
create sequence seq_capital_reference;
create or replace function next_capital_reference()
returns text language sql as $$
    select 'CAP-' || to_char(now(),'YYYY') || '-'
                  || lpad(nextval('seq_capital_reference')::text, 6, '0');
$$;

create table capital_contributions (
    id                  uuid primary key default gen_random_uuid(),
    reference           text not null unique default next_capital_reference(),
    shareholder_user_id uuid not null references users(id),
    amount              numeric(18,0) not null check (amount > 0),
    status              text not null default 'awaiting_receipt'
                            check (status in ('awaiting_receipt','confirmed','not_confirmed')),
    declared_by         uuid not null references users(id),
    declared_at         timestamptz not null default now(),
    confirmed_by        uuid references users(id),
    confirmed_at        timestamptz,
    not_confirmed_cause text,
    movement_id         uuid references treasury_movements(id),
    confirm_idempotency_key text unique,
    constraint chk_confirmed_has_movement
        check (status <> 'confirmed' or movement_id is not null),
    constraint chk_not_confirmed_has_cause
        check (status <> 'not_confirmed'
               or (not_confirmed_cause is not null and btrim(not_confirmed_cause) <> ''))
);

create index idx_capital_shareholder on capital_contributions(shareholder_user_id);

-- §13.1 rule 8: only the two shareholders (Super Admin, First-Level Validator).
create or replace function trg_capital_shareholder_check()
returns trigger language plpgsql as $$
begin
    if not exists (select 1 from users u join roles r on r.id = u.role_id
                   where u.id = new.shareholder_user_id
                     and r.code in ('super_admin','first_validator')) then
        raise exception 'Capital contributions accept only the two shareholders (§13.1 rule 8)'
            using errcode = '23514';
    end if;
    return new;
end;
$$;

create trigger trg_capital_shareholder
    before insert on capital_contributions
    for each row execute function trg_capital_shareholder_check();

-- Immutable except the single awaiting -> terminal transition done at confirm.
create or replace function trg_capital_guard()
returns trigger language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'Capital contributions cannot be deleted' using errcode = '23000';
    end if;
    if old.status <> 'awaiting_receipt' then
        raise exception 'A processed capital contribution is immutable' using errcode = '23000';
    end if;
    if row(old.reference, old.shareholder_user_id, old.amount, old.declared_by,
           old.declared_at)
       is distinct from
       row(new.reference, new.shareholder_user_id, new.amount, new.declared_by,
           new.declared_at) then
        raise exception 'Only the confirmation fields may change' using errcode = '23000';
    end if;
    return new;
end;
$$;

create trigger trg_capital_guard_upd
    before update or delete on capital_contributions
    for each row execute function trg_capital_guard();

-- §9.2 comparative summary across the two shareholders.
create view shareholder_capital_summary
with (security_invoker = true) as
    select shareholder_user_id,
           count(*)                                                    as contributions,
           coalesce(sum(amount) filter (where status='awaiting_receipt'),0) as total_awaiting,
           coalesce(sum(amount) filter (where status='confirmed'),0)        as total_confirmed,
           coalesce(sum(amount) filter (where status='not_confirmed'),0)    as total_not_confirmed
    from capital_contributions
    group by shareholder_user_id;

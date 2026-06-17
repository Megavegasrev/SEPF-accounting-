-- =============================================================================
-- SEPF Treasury — Milestone 6 (Investments and capital contributions)
-- Migration 0020: Row-Level Security and grants
-- =============================================================================

alter table investments           enable row level security;
alter table assets                enable row level security;
alter table capital_contributions enable row level security;

-- Investments / assets: visible to investment readers, or the requester.
create policy investments_read on investments
    for select using (
        app_has_permission('investment.read')
        or exists (select 1 from requests r
                   where r.id = investments.request_id
                     and r.requester_id = app_current_user_id())
    );

create policy assets_read on assets
    for select using (
        app_has_permission('investment.read')
        or exists (select 1 from investments i join requests r on r.id = i.request_id
                   where i.id = assets.investment_id
                     and r.requester_id = app_current_user_id())
    );

-- Capital: a shareholder sees their own history; capital.read sees all (§9.2).
create policy capital_read on capital_contributions
    for select using (
        app_has_permission('capital.read')
        or shareholder_user_id = app_current_user_id()
    );

-- --- grants ------------------------------------------------------------------
grant select on investments, assets, capital_contributions,
                asset_register, shareholder_capital_summary
to app_user;

grant execute on function create_investment(numeric, text, text, text, uuid, text, text) to app_user;
grant execute on function pay_investment(uuid, text, date) to app_user;
grant execute on function declare_capital_contribution(numeric) to app_user;
grant execute on function confirm_capital_contribution(uuid, boolean, text, text) to app_user;

grant select, insert, update, delete on investments, assets,
                capital_contributions to service_role;
grant usage, select on sequence seq_capital_reference to service_role;
grant execute on all functions in schema public to service_role;

-- =============================================================================
-- SEPF Treasury — Production hardening (forward-only)
-- Migration 0029 (Priority 2.6 & 2.7): cross-table integrity + status coherence
-- =============================================================================

-- --- 2.6a payment's version must belong to the payment's request -------------
alter table request_versions add constraint uq_rv_request_version unique (request_id, id);
alter table payments add constraint fk_payment_version_belongs
    foreign key (request_id, request_version_id) references request_versions(request_id, id);

-- --- 2.6b/c/d/e request-type guards (specialised op must link its request type)
create or replace function trg_request_type_guard()
returns trigger language plpgsql as $$
declare v_type text;
begin
    select request_type into v_type from requests where id = new.request_id;
    if v_type is distinct from tg_argv[0] then
        raise exception '% requires a "%" request (got "%")',
            tg_table_name, tg_argv[0], coalesce(v_type, 'unknown') using errcode = '23514';
    end if;
    return new;
end;
$$;
create trigger trg_investments_reqtype before insert on investments
    for each row execute function trg_request_type_guard('investment');
create trigger trg_loans_reqtype before insert on loans_granted
    for each row execute function trg_request_type_guard('loan');
create trigger trg_borrinst_reqtype before insert on borrowing_installments
    for each row execute function trg_request_type_guard('borrowing_repayment');
create trigger trg_sar_reqtype before insert on salary_advance_requests
    for each row execute function trg_request_type_guard('salary_advance');

-- --- 2.6 salary advance: user matches request requester and cycle user -------
create or replace function trg_salary_advance_coherence()
returns trigger language plpgsql as $$
declare v_requester uuid; v_cycle_user uuid;
begin
    select requester_id into v_requester from requests where id = new.request_id;
    select user_id into v_cycle_user from salary_cycles where id = new.cycle_id;
    if new.user_id is distinct from v_requester then
        raise exception 'Salary advance user must match the request requester' using errcode = '23514';
    end if;
    if new.user_id is distinct from v_cycle_user then
        raise exception 'Salary advance user must match the cycle user' using errcode = '23514';
    end if;
    return new;
end;
$$;
create trigger trg_sar_coherence before insert on salary_advance_requests
    for each row execute function trg_salary_advance_coherence();

-- --- 2.6 asset: investment, payment and movement coherence -------------------
create or replace function trg_assets_coherence()
returns trigger language plpgsql as $$
declare v_inv_req uuid; v_pay_req uuid; v_pay_mov uuid;
begin
    select request_id into v_inv_req from investments where id = new.investment_id;
    select request_id, movement_id into v_pay_req, v_pay_mov from payments where id = new.payment_id;
    if v_inv_req is distinct from v_pay_req then
        raise exception 'Asset payment must belong to the same request as the investment' using errcode = '23514';
    end if;
    if new.movement_id is distinct from v_pay_mov then
        raise exception 'Asset movement must equal the payment movement' using errcode = '23514';
    end if;
    return new;
end;
$$;
create trigger trg_assets_coherence before insert on assets
    for each row execute function trg_assets_coherence();

-- --- 2.6 transfer direction must match the account types ---------------------
create or replace function trg_transfer_direction_guard()
returns trigger language plpgsql as $$
declare v_src text; v_dst text; v_tr text;
begin
    select account_type into v_src from treasury_accounts where id = new.source_account_id;
    select account_type into v_dst from treasury_accounts where id = new.destination_account_id;
    select account_type into v_tr  from treasury_accounts where id = new.transit_account_id;
    if v_tr is distinct from 'funds_in_transit' then
        raise exception 'Transfer transit account must be the funds_in_transit account' using errcode = '23514';
    end if;
    if new.direction = 'small_to_large' and not (v_src = 'small_treasury' and v_dst = 'large_treasury') then
        raise exception 'A small_to_large transfer must move small -> large' using errcode = '23514';
    end if;
    if new.direction = 'large_to_small' and not (v_src = 'large_treasury' and v_dst = 'small_treasury') then
        raise exception 'A large_to_small transfer must move large -> small' using errcode = '23514';
    end if;
    return new;
end;
$$;
create trigger trg_transfer_direction before insert on internal_transfers
    for each row execute function trg_transfer_direction_guard();

-- --- 2.7 status coherence: processed statuses require actor/timestamp --------
alter table internal_transfers
    add constraint chk_transfer_confirmed_actor
    check (status <> 'confirmed' or (confirmed_by is not null and confirmed_at is not null));
alter table internal_transfers
    add constraint chk_transfer_cancelled_actor
    check (status <> 'cancelled' or (cancelled_by is not null and cancelled_at is not null
                                     and cancel_reason is not null));

alter table capital_contributions
    add constraint chk_capital_confirmed_actor
    check (status <> 'confirmed' or (confirmed_by is not null and confirmed_at is not null));
alter table capital_contributions
    add constraint chk_capital_not_confirmed_actor
    check (status <> 'not_confirmed' or (confirmed_by is not null and confirmed_at is not null));

alter table company_borrowings
    add constraint chk_borrowing_received_actor
    check (status <> 'received' or (confirmed_by is not null and confirmed_at is not null));
alter table company_borrowings
    add constraint chk_borrowing_not_received_actor
    check (status <> 'not_received' or (confirmed_by is not null and confirmed_at is not null));

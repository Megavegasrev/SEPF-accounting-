-- =============================================================================
-- SEPF Treasury — Production hardening (forward-only)
-- Migration 0026 (Priority 1.2): protect treasury_accounts
-- -----------------------------------------------------------------------------
-- Once a treasury account has any movement:
--   * opening_balance is frozen;
--   * account_type and currency are frozen;
--   * the account cannot be deleted.
-- Corrections to balances are made through movements (adjustment/reversal), never
-- by editing the account. Editable after use: name, responsible_user_id, is_active.
-- =============================================================================

create or replace function trg_treasury_account_guard()
returns trigger language plpgsql as $$
declare
    v_used boolean;
begin
    if tg_op = 'DELETE' then
        if exists (select 1 from treasury_movements where account_id = old.id) then
            raise exception 'A used treasury account cannot be deleted (correct via a movement instead)'
                using errcode = '23000';
        end if;
        return old;
    end if;

    v_used := exists (select 1 from treasury_movements where account_id = old.id);
    if v_used then
        if new.opening_balance is distinct from old.opening_balance then
            raise exception 'Opening balance cannot be changed after the first movement'
                using errcode = '23000';
        end if;
        if new.account_type is distinct from old.account_type then
            raise exception 'Account type cannot be changed after the account is in use'
                using errcode = '23000';
        end if;
        if new.currency is distinct from old.currency then
            raise exception 'Currency cannot be changed after the account is in use'
                using errcode = '23000';
        end if;
    end if;
    return new;
end;
$$;

create trigger trg_treasury_accounts_guard
    before update or delete on treasury_accounts
    for each row execute function trg_treasury_account_guard();

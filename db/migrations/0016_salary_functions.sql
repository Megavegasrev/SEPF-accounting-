-- =============================================================================
-- SEPF Treasury — Milestone 5 (Salaries and advances)
-- Migration 0016: Transactional functions
--   set_salary_profile · ensure_salary_cycle · request_salary_advance
--   pay_salary_advance · pay_salary_balance
-- Also re-creates pay_request to route salary advances to their dedicated,
-- ceiling-checked payment path.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- set_salary_profile — §8.1. Super Administrator only. Appends an effective-
-- dated profile row (history, no retroactive effect). Ceiling <= salary is
-- enforced by the table constraint.
-- -----------------------------------------------------------------------------
create or replace function set_salary_profile(
    p_user_id             uuid,
    p_salary_eligible     boolean,
    p_monthly_salary      numeric,
    p_can_request_advance boolean,
    p_advance_ceiling     numeric,
    p_effective_date      date,
    p_note                text default null
)
returns salary_profiles
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_row   salary_profiles;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('salary.configure') then
        raise exception 'Not authorised to configure salaries (§8.1)' using errcode = '42501';
    end if;

    insert into salary_profiles (user_id, salary_eligible, monthly_salary,
                                 can_request_advance, monthly_advance_ceiling,
                                 effective_date, note, created_by)
    values (p_user_id, p_salary_eligible, p_monthly_salary, p_can_request_advance,
            coalesce(p_advance_ceiling, 0), p_effective_date, p_note, v_actor)
    returning * into v_row;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'salary.configure', 'user', p_user_id, to_jsonb(v_row));

    return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- ensure_salary_cycle — internal. Returns the cycle for (user, month), creating
-- it from the salary profile in force at the month start (snapshot). Raises if
-- the user has no active, salary-eligible profile then.
-- -----------------------------------------------------------------------------
create or replace function ensure_salary_cycle(p_user_id uuid, p_period date)
returns salary_cycles
language plpgsql security definer set search_path = public
as $$
declare
    v_period date := date_trunc('month', p_period)::date;
    v_prof   salary_profiles;
    v_cycle  salary_cycles;
begin
    select * into v_cycle from salary_cycles
    where user_id = p_user_id and period = v_period;
    if found then
        return v_cycle;
    end if;

    select * into v_prof from salary_profiles
    where user_id = p_user_id and is_active and effective_date <= v_period
    order by effective_date desc limit 1;
    if not found or not v_prof.salary_eligible then
        raise exception 'No active salary profile for this user and period (§8.1)'
            using errcode = '23514';
    end if;

    insert into salary_cycles (user_id, period, monthly_salary, advance_ceiling,
                               can_request_advance)
    values (p_user_id, v_period, v_prof.monthly_salary, v_prof.monthly_advance_ceiling,
            v_prof.can_request_advance)
    on conflict (user_id, period) do nothing
    returning * into v_cycle;

    if v_cycle.id is null then
        select * into v_cycle from salary_cycles
        where user_id = p_user_id and period = v_period;
    end if;

    return v_cycle;
end;
$$;

-- -----------------------------------------------------------------------------
-- open_salary_cycle — opens (or returns) a user's monthly cycle so a balance can
-- be settled even when no advance was taken. For the salary-runner (salary.pay).
-- -----------------------------------------------------------------------------
create or replace function open_salary_cycle(p_user_id uuid, p_period date)
returns salary_cycles
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('salary.pay') then
        raise exception 'Not authorised to open a salary cycle' using errcode = '42501';
    end if;
    return ensure_salary_cycle(p_user_id, p_period);
end;
$$;

-- -----------------------------------------------------------------------------
-- request_salary_advance — §8.2. The user requests an advance for a month; it
-- becomes a generic request (type salary_advance, internal beneficiary = self,
-- large treasury) that follows the normal approval workflow. Checks eligibility
-- and that the amount fits the available ceiling at creation time.
-- -----------------------------------------------------------------------------
create or replace function request_salary_advance(
    p_period date,
    p_amount numeric
)
returns salary_advance_requests
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_cycle salary_cycles;
    v_avail numeric(18,0);
    v_req   requests;
    v_sar   salary_advance_requests;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('request.create') then
        raise exception 'Not authorised to create a request' using errcode = '42501';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Advance amount must be a positive integer' using errcode = '23514';
    end if;

    v_cycle := ensure_salary_cycle(v_actor, p_period);
    if not v_cycle.can_request_advance then
        raise exception 'You are not permitted to request a salary advance (§8.1)'
            using errcode = '42501';
    end if;

    v_avail := v_cycle.advance_ceiling
               - salary_advances_paid(v_cycle.id)
               - salary_advances_approved_unpaid(v_cycle.id);
    if p_amount > v_avail then
        raise exception
            'Advance % exceeds the available amount % for this month (§8.2)',
            p_amount, v_avail using errcode = '23514';
    end if;

    insert into requests (request_type, requester_id)
    values ('salary_advance', v_actor) returning * into v_req;

    insert into request_versions (request_id, version_number, amount,
        beneficiary_type, beneficiary_user_id, purpose, category,
        proposed_treasury, created_by)
    values (v_req.id, 1, p_amount, 'internal', v_actor, 'Salary advance',
            'salary_advance', 'large_treasury', v_actor);

    insert into salary_advance_requests (request_id, cycle_id, user_id, amount)
    values (v_req.id, v_cycle.id, v_actor, p_amount) returning * into v_sar;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'salary.advance.request', 'request', v_req.id, to_jsonb(v_sar));

    return v_sar;
end;
$$;

-- -----------------------------------------------------------------------------
-- pay_salary_advance — §8.2 payment by the Accountant from the large treasury,
-- after both approvals. Repeats the ceiling check transactionally; full amount
-- only; insufficient large treasury pays nothing. One payment per request.
-- -----------------------------------------------------------------------------
create or replace function pay_salary_advance(p_request_id uuid, p_idempotency_key text)
returns payments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor      uuid := app_current_user_id();
    v_sar        salary_advance_requests;
    v_version    request_versions;
    v_cycle      salary_cycles;
    v_account    treasury_accounts;
    v_balance    numeric(18,0);
    v_payment    payments;
    v_payment_id uuid := gen_random_uuid();
    v_movement   treasury_movements;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('salary.pay') then
        raise exception 'Not authorised to pay salaries (§8.2)' using errcode = '42501';
    end if;

    select * into v_sar from salary_advance_requests where request_id = p_request_id;
    if not found then
        raise exception 'Request % is not a salary advance', p_request_id using errcode = '23503';
    end if;

    select * into v_payment from payments where request_id = p_request_id;
    if found then
        return v_payment;   -- idempotent: already paid
    end if;

    select * into v_version from request_versions
    where request_id = p_request_id and status = 'approved';
    if not found then
        raise exception 'The salary advance has no approved version to pay' using errcode = '23514';
    end if;

    select * into v_cycle from salary_cycles where id = v_sar.cycle_id;

    -- §8.2 transactional re-check: paid + approved-unpaid must not exceed the
    -- ceiling (catches a ceiling lowered after approval).
    if salary_advances_paid(v_cycle.id) + salary_advances_approved_unpaid(v_cycle.id)
       > v_cycle.advance_ceiling then
        raise exception 'Paying this advance would exceed the monthly ceiling (§8.2)'
            using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where account_type = 'large_treasury' for update;
    select v_account.opening_balance + coalesce(sum(m.amount), 0) into v_balance
    from treasury_movements m where m.account_id = v_account.id;
    if v_balance < v_version.amount then
        raise exception 'Insufficient large treasury: nothing is paid (§6.7)' using errcode = '23514';
    end if;

    v_movement := post_treasury_movement(v_account.id, -v_version.amount, 'salary_advance',
        p_idempotency_key, v_actor, 'payment', v_payment_id, null, null,
        'Salary advance payment', 'salary.advance.pay');

    insert into payments (id, request_id, request_version_id, treasury_account_id,
                          amount, movement_id, is_advance, status, paid_by)
    values (v_payment_id, p_request_id, v_version.id, v_account.id,
            v_version.amount, v_movement.id, false, 'completed', v_actor)
    returning * into v_payment;

    return v_payment;
end;
$$;

-- -----------------------------------------------------------------------------
-- pay_salary_balance — §8.3. The Accountant settles a cycle's outstanding
-- balance in full from the large treasury. Insufficient funds => nothing paid,
-- the amount remains due. Idempotent on its key.
-- -----------------------------------------------------------------------------
create or replace function pay_salary_balance(p_cycle_id uuid, p_idempotency_key text)
returns salary_balance_payments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor       uuid := app_current_user_id();
    v_cycle       salary_cycles;
    v_outstanding numeric(18,0);
    v_account     treasury_accounts;
    v_balance     numeric(18,0);
    v_movement    treasury_movements;
    v_row         salary_balance_payments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('salary.pay') then
        raise exception 'Not authorised to pay salaries (§8.3)' using errcode = '42501';
    end if;

    select * into v_row from salary_balance_payments where idempotency_key = p_idempotency_key;
    if found then
        return v_row;   -- idempotent
    end if;

    select * into v_cycle from salary_cycles where id = p_cycle_id;
    if not found then
        raise exception 'Unknown salary cycle %', p_cycle_id using errcode = '23503';
    end if;

    v_outstanding := v_cycle.monthly_salary
                     - salary_advances_paid(p_cycle_id)
                     - salary_balance_paid(p_cycle_id);
    if v_outstanding <= 0 then
        raise exception 'No outstanding salary balance for this cycle' using errcode = '23514';
    end if;

    select * into v_account from treasury_accounts where account_type = 'large_treasury' for update;
    select v_account.opening_balance + coalesce(sum(m.amount), 0) into v_balance
    from treasury_movements m where m.account_id = v_account.id;
    if v_balance < v_outstanding then
        raise exception 'Insufficient large treasury: the balance remains due (§8.3)'
            using errcode = '23514';
    end if;

    v_movement := post_treasury_movement(v_account.id, -v_outstanding, 'salary',
        p_idempotency_key, v_actor, 'salary_balance', p_cycle_id, null, null,
        'Monthly salary balance', 'salary.balance.pay');

    insert into salary_balance_payments (cycle_id, amount, movement_id,
                                         idempotency_key, paid_by)
    values (p_cycle_id, v_outstanding, v_movement.id, p_idempotency_key, v_actor)
    returning * into v_row;

    return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- pay_request — re-created to refuse non-expense requests, so salary advances
-- (and future specialised types) must use their dedicated payment function.
-- -----------------------------------------------------------------------------
create or replace function pay_request(p_request_id uuid, p_idempotency_key text)
returns payments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor      uuid := app_current_user_id();
    v_type       text;
    v_version    request_versions;
    v_account    treasury_accounts;
    v_balance    numeric(18,0);
    v_payment_id uuid := gen_random_uuid();
    v_movement   treasury_movements;
    v_payment    payments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;

    select request_type into v_type from requests where id = p_request_id;
    if v_type is null then
        raise exception 'Unknown request %', p_request_id using errcode = '23503';
    end if;
    if v_type <> 'expense' then
        raise exception 'Request type "%" has a dedicated payment function', v_type
            using errcode = '23514';
    end if;

    select * into v_payment from payments where request_id = p_request_id;
    if found then
        if v_payment.is_advance then
            raise exception 'This request was disbursed as an advance; use the advance flow'
                using errcode = '23505';
        end if;
        return v_payment;
    end if;

    select * into v_version from request_versions
    where request_id = p_request_id and status = 'approved';
    if not found then
        raise exception 'Request % has no approved version to pay', p_request_id
            using errcode = '23514';
    end if;

    if v_version.proposed_treasury = 'small_treasury' then
        if not app_has_permission('expense.pay.small') then
            raise exception 'Not authorised to pay from the small treasury' using errcode = '42501';
        end if;
    else
        if not app_has_permission('expense.pay.large') then
            raise exception 'Not authorised to pay from the large treasury' using errcode = '42501';
        end if;
    end if;

    select * into v_account from treasury_accounts
    where account_type = v_version.proposed_treasury for update;
    select v_account.opening_balance + coalesce(sum(m.amount), 0) into v_balance
    from treasury_movements m where m.account_id = v_account.id;
    if v_balance < v_version.amount then
        raise exception
            'Insufficient balance: nothing is paid and the request stays pending (§6.7)'
            using errcode = '23514';
    end if;

    v_movement := post_treasury_movement(v_account.id, -v_version.amount, 'expense',
        p_idempotency_key, v_actor, 'payment', v_payment_id, null, null,
        'Payment of request', 'expense.pay');

    insert into payments (id, request_id, request_version_id, treasury_account_id,
                          amount, movement_id, is_advance, status, paid_by)
    values (v_payment_id, p_request_id, v_version.id, v_account.id,
            v_version.amount, v_movement.id, false, 'completed', v_actor)
    returning * into v_payment;

    return v_payment;
end;
$$;

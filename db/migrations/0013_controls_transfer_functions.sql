-- =============================================================================
-- SEPF Treasury — Milestone 4 (Controls and transfers)
-- Migration 0013: Transactional functions
--   record_accounting_control · add_attachment · replace_attachment
--   confirm_internal_receipt · initiate_transfer · confirm_transfer
--   cancel_transfer (proposed safeguard)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- record_accounting_control — §7.2. Two decisions; a cause is mandatory for
-- "not validated". NO financial effect (no movement, no credit, no refund).
-- -----------------------------------------------------------------------------
create or replace function record_accounting_control(
    p_payment_id uuid,
    p_decision   text,
    p_cause      text default null,
    p_comment    text default null
)
returns accounting_controls
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_ctrl  accounting_controls;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('accounting.control') then
        raise exception 'Not authorised to perform an accounting control'
            using errcode = '42501';
    end if;
    if p_decision not in ('validated','not_validated') then
        raise exception 'Invalid control decision %', p_decision using errcode = '23514';
    end if;
    if p_decision = 'not_validated' and coalesce(btrim(p_cause),'') = '' then
        raise exception 'A cause is mandatory when a control is not validated (§7.2)'
            using errcode = '23514';
    end if;
    if not exists (select 1 from payments where id = p_payment_id) then
        raise exception 'Unknown payment %', p_payment_id using errcode = '23503';
    end if;

    insert into accounting_controls (payment_id, decision, cause, comment, controlled_by)
    values (p_payment_id, p_decision, nullif(btrim(p_cause),''),
            nullif(btrim(p_comment),''), v_actor)
    returning * into v_ctrl;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'accounting.control', 'payment', p_payment_id, to_jsonb(v_ctrl));

    return v_ctrl;
end;
$$;

-- -----------------------------------------------------------------------------
-- add_attachment — §7.1. Flags a potential reuse when the same hash already
-- exists on an active attachment (detect, do not block).
-- -----------------------------------------------------------------------------
create or replace function add_attachment(
    p_entity_type text,
    p_entity_id   uuid,
    p_file_name   text,
    p_mime_type   text,
    p_byte_size   bigint,
    p_storage_path text,
    p_sha256      text
)
returns attachments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_dup   uuid;
    v_row   attachments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('attachment.add') then
        raise exception 'Not authorised to add an attachment' using errcode = '42501';
    end if;

    select id into v_dup from attachments
    where sha256 = p_sha256 and is_active order by uploaded_at limit 1;

    insert into attachments (entity_type, entity_id, file_name, mime_type,
                             byte_size, storage_path, sha256,
                             is_potential_duplicate, duplicate_of_id, uploaded_by)
    values (p_entity_type, p_entity_id, p_file_name, p_mime_type, p_byte_size,
            p_storage_path, p_sha256, (v_dup is not null), v_dup, v_actor)
    returning * into v_row;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'attachment.add', p_entity_type, p_entity_id, to_jsonb(v_row));

    return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- replace_attachment — §7.1. Keeps the original (is_active=false, linked forward)
-- and inserts the replacement; both rows and the action are auditable.
-- -----------------------------------------------------------------------------
create or replace function replace_attachment(
    p_old_id      uuid,
    p_file_name   text,
    p_mime_type   text,
    p_byte_size   bigint,
    p_storage_path text,
    p_sha256      text
)
returns attachments
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_old   attachments;
    v_new   attachments;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if not app_has_permission('attachment.add') then
        raise exception 'Not authorised to replace an attachment' using errcode = '42501';
    end if;

    select * into v_old from attachments where id = p_old_id;
    if not found then
        raise exception 'Unknown attachment %', p_old_id using errcode = '23503';
    end if;

    v_new := add_attachment(v_old.entity_type, v_old.entity_id, p_file_name,
                            p_mime_type, p_byte_size, p_storage_path, p_sha256);

    update attachments set is_active = false, replaced_by_id = v_new.id
    where id = p_old_id;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id,
                            before, after)
    values (v_actor, 'attachment.replace', v_old.entity_type, v_old.entity_id,
            to_jsonb(v_old), to_jsonb(v_new));

    return v_new;
end;
$$;

-- -----------------------------------------------------------------------------
-- confirm_internal_receipt — §7.4. Only the beneficiary may acknowledge; never
-- posts a treasury movement.
-- -----------------------------------------------------------------------------
create or replace function confirm_internal_receipt(
    p_payment_id uuid,
    p_status     text,
    p_comment    text default null
)
returns internal_receipts
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_benef uuid;
    v_row   internal_receipts;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if p_status not in ('received','not_received','disputed') then
        raise exception 'Invalid receipt status %', p_status using errcode = '23514';
    end if;

    select v.beneficiary_user_id into v_benef
    from payments p join request_versions v on v.id = p.request_version_id
    where p.id = p_payment_id;
    if not found then
        raise exception 'Unknown payment %', p_payment_id using errcode = '23503';
    end if;
    if v_benef is null then
        raise exception 'This payment has no internal beneficiary (§7.3)'
            using errcode = '23514';
    end if;
    if v_benef <> v_actor then
        raise exception 'Only the beneficiary may confirm receipt' using errcode = '42501';
    end if;

    insert into internal_receipts (payment_id, beneficiary_user_id, status, comment)
    values (p_payment_id, v_benef, p_status, nullif(btrim(p_comment),''))
    returning * into v_row;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'internal_receipt.confirm', 'payment', p_payment_id,
            to_jsonb(v_row));

    return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- initiate_transfer — §10.3 send leg. Source decreases, funds-in-transit
-- increases (balanced, so consolidated is unchanged). Idempotent on its key.
-- -----------------------------------------------------------------------------
create or replace function initiate_transfer(
    p_direction       text,
    p_amount          numeric,
    p_idempotency_key text
)
returns internal_transfers
language plpgsql security definer set search_path = public
as $$
declare
    v_actor    uuid := app_current_user_id();
    v_id       uuid := gen_random_uuid();
    v_src_type text;
    v_dst_type text;
    v_perm     text;
    v_transit  treasury_accounts;
    v_src      treasury_accounts;
    v_bal      numeric(18,0);
    v_t        internal_transfers;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if p_amount is null or p_amount <= 0 then
        raise exception 'Transfer amount must be a positive integer' using errcode = '23514';
    end if;

    if p_direction = 'small_to_large' then
        v_src_type := 'small_treasury'; v_dst_type := 'large_treasury';
        v_perm := 'transfer.initiate.small_to_large';
    elsif p_direction = 'large_to_small' then
        v_src_type := 'large_treasury'; v_dst_type := 'small_treasury';
        v_perm := 'transfer.initiate.large_to_small';
    else
        raise exception 'Invalid transfer direction %', p_direction using errcode = '23514';
    end if;
    if not app_has_permission(v_perm) then
        raise exception 'Not authorised to initiate this transfer direction'
            using errcode = '42501';
    end if;

    select * into v_transit from treasury_accounts where account_type = 'funds_in_transit';

    -- Reserve the workflow row first; the unique idempotency_key serialises
    -- concurrent retries so the legs below are posted exactly once.
    insert into internal_transfers (id, idempotency_key, direction, amount, status,
                                    source_account_id, destination_account_id,
                                    transit_account_id, initiated_by)
    select v_id, p_idempotency_key, p_direction, p_amount, 'pending',
           s.id, d.id, v_transit.id, v_actor
    from treasury_accounts s, treasury_accounts d
    where s.account_type = v_src_type and d.account_type = v_dst_type
    on conflict (idempotency_key) do nothing
    returning * into v_t;

    if v_t.id is null then
        select * into v_t from internal_transfers where idempotency_key = p_idempotency_key;
        return v_t;   -- idempotent replay
    end if;

    -- Lock the source treasury, then verify funds before sending.
    select * into v_src from treasury_accounts where id = v_t.source_account_id for update;
    select v_src.opening_balance + coalesce(sum(m.amount), 0) into v_bal
    from treasury_movements m where m.account_id = v_src.id;
    if v_bal < p_amount then
        raise exception 'Insufficient balance to send this transfer (§6.7)'
            using errcode = '23514';
    end if;

    perform post_treasury_movement(v_src.id, -p_amount, 'transfer_out',
        v_id::text || ':send:src', v_actor, 'internal_transfer', v_id, v_id, null,
        'Transfer sent', 'transfer.send');
    perform post_treasury_movement(v_transit.id, p_amount, 'transfer_in',
        v_id::text || ':send:transit', v_actor, 'internal_transfer', v_id, v_id, null,
        'Transfer in transit', 'transfer.send');

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'transfer.initiate', 'internal_transfer', v_id, to_jsonb(v_t));

    return v_t;
end;
$$;

-- -----------------------------------------------------------------------------
-- confirm_transfer — §10.3 confirm leg. Funds-in-transit decreases, destination
-- increases. The confirmed amount equals the amount sent (same row). Idempotent.
-- -----------------------------------------------------------------------------
create or replace function confirm_transfer(p_transfer_id uuid)
returns internal_transfers
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_t     internal_transfers;
    v_perm  text;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;

    select * into v_t from internal_transfers where id = p_transfer_id for update;
    if not found then
        raise exception 'Unknown transfer %', p_transfer_id using errcode = '23503';
    end if;
    if v_t.status = 'confirmed' then
        return v_t;   -- idempotent
    end if;
    if v_t.status = 'cancelled' then
        raise exception 'A cancelled transfer cannot be confirmed' using errcode = '23514';
    end if;

    v_perm := case v_t.direction
                  when 'small_to_large' then 'transfer.confirm.small_to_large'
                  else 'transfer.confirm.large_to_small' end;
    if not app_has_permission(v_perm) then
        raise exception 'Not authorised to confirm this transfer direction'
            using errcode = '42501';
    end if;

    perform post_treasury_movement(v_t.transit_account_id, -v_t.amount, 'transfer_out',
        v_t.id::text || ':confirm:transit', v_actor, 'internal_transfer', v_t.id, v_t.id,
        null, 'Transfer received - leaving transit', 'transfer.confirm');
    perform post_treasury_movement(v_t.destination_account_id, v_t.amount, 'transfer_in',
        v_t.id::text || ':confirm:dst', v_actor, 'internal_transfer', v_t.id, v_t.id,
        null, 'Transfer received', 'transfer.confirm');

    update internal_transfers set status = 'confirmed', confirmed_by = v_actor,
           confirmed_at = now() where id = p_transfer_id returning * into v_t;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'transfer.confirm', 'internal_transfer', p_transfer_id, to_jsonb(v_t));

    return v_t;
end;
$$;

-- -----------------------------------------------------------------------------
-- cancel_transfer — PROPOSED safeguard (not in the spec; flagged in the review)
-- for a transfer that is never confirmed. Only the initiator, only while
-- pending; reverses the transit leg back to the source, conserving the
-- consolidated total. Requires SEPF sign-off before production use (§19.1).
-- -----------------------------------------------------------------------------
create or replace function cancel_transfer(p_transfer_id uuid, p_reason text)
returns internal_transfers
language plpgsql security definer set search_path = public
as $$
declare
    v_actor uuid := app_current_user_id();
    v_t     internal_transfers;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '28000';
    end if;
    if coalesce(btrim(p_reason),'') = '' then
        raise exception 'A reason is mandatory to cancel a transfer' using errcode = '23514';
    end if;

    select * into v_t from internal_transfers where id = p_transfer_id for update;
    if not found then
        raise exception 'Unknown transfer %', p_transfer_id using errcode = '23503';
    end if;
    if v_t.initiated_by <> v_actor then
        raise exception 'Only the initiator may cancel a transfer' using errcode = '42501';
    end if;
    if v_t.status <> 'pending' then
        raise exception 'Only a pending transfer can be cancelled' using errcode = '23514';
    end if;

    perform post_treasury_movement(v_t.transit_account_id, -v_t.amount, 'transfer_out',
        v_t.id::text || ':cancel:transit', v_actor, 'internal_transfer', v_t.id, v_t.id,
        null, 'Transfer cancelled - leaving transit', 'transfer.cancel');
    perform post_treasury_movement(v_t.source_account_id, v_t.amount, 'transfer_in',
        v_t.id::text || ':cancel:src', v_actor, 'internal_transfer', v_t.id, v_t.id,
        null, 'Transfer cancelled - returned to source', 'transfer.cancel');

    update internal_transfers set status = 'cancelled', cancelled_by = v_actor,
           cancelled_at = now(), cancel_reason = btrim(p_reason)
    where id = p_transfer_id returning * into v_t;

    insert into audit_logs (actor_user_id, action, entity_type, entity_id, after)
    values (v_actor, 'transfer.cancel', 'internal_transfer', p_transfer_id, to_jsonb(v_t));

    return v_t;
end;
$$;

-- =============================================================================
-- SEPF Treasury — Milestone 4 (Controls and transfers)
-- Migration 0011: Supporting documents, accounting controls, internal receipts
-- -----------------------------------------------------------------------------
-- Spec references:
--   §7.1  supporting documents: evidence attached, original preserved, any
--         replacement leaves an audit trace, reuse detected via a digital hash
--   §7.2  the Accountant's two decisions: control validated / not validated
--         (a cause is mandatory for "not validated"); NO financial effect
--   §7.4  internal beneficiaries may state received / not received / disputed —
--         this never creates a second treasury movement
-- =============================================================================

-- -----------------------------------------------------------------------------
-- attachments — polymorphic evidence for a request version, payment, transfer,
-- etc. No hard FK on entity_id (kept generic, like the ledger's source link).
-- Content is immutable; a replacement keeps the original (is_active=false) and
-- links forward via replaced_by_id (§7.1). sha256 enables reuse detection.
-- -----------------------------------------------------------------------------
create table attachments (
    id                   uuid primary key default gen_random_uuid(),
    entity_type          text not null,    -- e.g. payment, request_version, internal_transfer
    entity_id            uuid not null,
    file_name            text not null,
    mime_type            text not null,
    byte_size            bigint not null check (byte_size > 0),
    storage_path         text not null,    -- private-bucket key (signed URLs at read time)
    sha256               text not null,    -- digital hash (§7.1 reuse detection)
    is_potential_duplicate boolean not null default false,
    duplicate_of_id      uuid references attachments(id),
    is_active            boolean not null default true,
    replaced_by_id       uuid references attachments(id),
    uploaded_by          uuid not null references users(id),
    uploaded_at          timestamptz not null default now()
);

create index idx_attachments_entity on attachments(entity_type, entity_id);
create index idx_attachments_sha256 on attachments(sha256);

-- Content is frozen; only is_active / replaced_by_id may change (§7.1).
create or replace function trg_attachment_immutable_fields()
returns trigger language plpgsql as $$
begin
    if row(old.entity_type, old.entity_id, old.file_name, old.mime_type,
           old.byte_size, old.storage_path, old.sha256, old.uploaded_by,
           old.uploaded_at)
       is distinct from
       row(new.entity_type, new.entity_id, new.file_name, new.mime_type,
           new.byte_size, new.storage_path, new.sha256, new.uploaded_by,
           new.uploaded_at)
    then
        raise exception 'Attachment content is immutable; upload a replacement instead (§7.1).'
            using errcode = '23000';
    end if;
    return new;
end;
$$;

create trigger trg_attachments_freeze
    before update on attachments
    for each row execute function trg_attachment_immutable_fields();
create trigger trg_attachments_no_delete
    before delete on attachments
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- accounting_controls — the Accountant's control of a payment (§7.2). Append-
-- only history; the latest row is the current status. A control has NO financial
-- effect: it never posts a movement, credits the treasury or creates a refund.
-- -----------------------------------------------------------------------------
create table accounting_controls (
    id            uuid primary key default gen_random_uuid(),
    payment_id    uuid not null references payments(id),
    decision      text not null check (decision in ('validated','not_validated')),
    cause         text,         -- mandatory when not validated (§7.2)
    comment       text,
    controlled_by uuid not null references users(id),
    controlled_at timestamptz not null default now(),
    constraint chk_control_cause check (
        decision = 'validated' or (cause is not null and btrim(cause) <> '')
    )
);

create index idx_controls_payment on accounting_controls(payment_id, controlled_at desc);

create trigger trg_controls_immutable
    before update or delete on accounting_controls
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- internal_receipts — an internal beneficiary's acknowledgement (§7.4). Append-
-- only; never posts a treasury movement.
-- -----------------------------------------------------------------------------
create table internal_receipts (
    id          uuid primary key default gen_random_uuid(),
    payment_id  uuid not null references payments(id),
    beneficiary_user_id uuid not null references users(id),
    status      text not null check (status in ('received','not_received','disputed')),
    comment     text,
    recorded_at timestamptz not null default now()
);

create index idx_receipts_payment on internal_receipts(payment_id, recorded_at desc);

create trigger trg_receipts_immutable
    before update or delete on internal_receipts
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- Convenience read models: the current control status per payment, and the set
-- of completed payments still awaiting a control (for the Accountant dashboard).
-- -----------------------------------------------------------------------------
create view payment_control_status
with (security_invoker = true) as
    select p.id as payment_id,
           p.request_id,
           p.status as payment_status,
           c.decision as control_decision,
           c.controlled_at,
           c.controlled_by
    from payments p
    left join lateral (
        select * from accounting_controls ac
        where ac.payment_id = p.id
        order by ac.controlled_at desc limit 1
    ) c on true;

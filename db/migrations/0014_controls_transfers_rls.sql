-- =============================================================================
-- SEPF Treasury — Milestone 4 (Controls and transfers)
-- Migration 0014: Row-Level Security and grants
-- =============================================================================

alter table attachments         enable row level security;
alter table accounting_controls enable row level security;
alter table internal_receipts   enable row level security;
alter table internal_transfers  enable row level security;

-- Attachments: full readers, or the uploader. (Per-entity visibility can be
-- tightened later; kept simple here — see docs.)
create policy attachments_read on attachments
    for select using (
        app_has_permission('request.read.all')
        or uploaded_by = app_current_user_id()
    );

-- Accounting controls: full readers, the controller, or the requester of the
-- underlying request.
create policy controls_read on accounting_controls
    for select using (
        app_has_permission('request.read.all')
        or controlled_by = app_current_user_id()
        or exists (select 1 from payments p join requests r on r.id = p.request_id
                   where p.id = accounting_controls.payment_id
                     and r.requester_id = app_current_user_id())
    );

-- Internal receipts: full readers, the beneficiary, or the requester.
create policy receipts_read on internal_receipts
    for select using (
        app_has_permission('request.read.all')
        or beneficiary_user_id = app_current_user_id()
        or exists (select 1 from payments p join requests r on r.id = p.request_id
                   where p.id = internal_receipts.payment_id
                     and r.requester_id = app_current_user_id())
    );

-- Transfers: anyone with treasury visibility (the two operators + full readers).
create policy transfers_read on internal_transfers
    for select using (app_has_permission('transfer.read'));

-- --- grants ------------------------------------------------------------------
grant select on attachments, accounting_controls, internal_receipts,
                internal_transfers, payment_control_status
to app_user;

grant execute on function record_accounting_control(uuid, text, text, text) to app_user;
grant execute on function add_attachment(text, uuid, text, text, bigint, text, text) to app_user;
grant execute on function replace_attachment(uuid, text, text, bigint, text, text) to app_user;
grant execute on function confirm_internal_receipt(uuid, text, text) to app_user;
grant execute on function initiate_transfer(text, numeric, text) to app_user;
grant execute on function confirm_transfer(uuid) to app_user;
grant execute on function cancel_transfer(uuid, text) to app_user;

grant select, insert, update, delete on attachments, accounting_controls,
                internal_receipts, internal_transfers to service_role;
grant usage, select on sequence seq_transfer_reference to service_role;
grant execute on all functions in schema public to service_role;

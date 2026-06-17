-- =============================================================================
-- SEPF Treasury — Milestone 3 (Requests and expenses)
-- Migration 0008: Requests, versions, validations (decisions), payments
-- -----------------------------------------------------------------------------
-- Spec references:
--   §6.1  request form fields & unique reference
--   §6.2  decisions: approve / do not approve / request correction (comment
--         mandatory for the latter two); final only after first approval
--   §6.3  request versioning — a correction creates a NEW version; only one
--         version may be approved (§13.1 rule 2); decisions are per-version
--   §6.5  small expense already disbursed (handled in 0009)
--   §6.7  no partial payments; one payment per request (§13.1 rule 3); the
--         payment is linked to the approved version, same amount (rule 4)
-- =============================================================================

-- Human-readable unique request reference: REQ-YYYY-000123 (§6.1).
create sequence seq_request_reference;
create or replace function next_request_reference()
returns text language sql as $$
    select 'REQ-' || to_char(now(), 'YYYY') || '-'
                  || lpad(nextval('seq_request_reference')::text, 6, '0');
$$;

-- -----------------------------------------------------------------------------
-- requests — the request header. The mutable details live on its versions;
-- the current state is derived from the latest version (see request_overview).
-- -----------------------------------------------------------------------------
create table requests (
    id           uuid primary key default gen_random_uuid(),
    reference    text not null unique default next_request_reference(),
    request_type text not null default 'expense'
                     check (request_type in ('expense')),  -- extended later
    requester_id uuid not null references users(id),
    created_at   timestamptz not null default now()
);

create index idx_requests_requester on requests(requester_id);

-- -----------------------------------------------------------------------------
-- request_versions — one row per submitted version (§6.3). A correction never
-- edits a version; it supersedes it and inserts a new one. Only the status of a
-- version may change after creation (guarded by trigger below).
-- -----------------------------------------------------------------------------
create table request_versions (
    id                  uuid primary key default gen_random_uuid(),
    request_id          uuid not null references requests(id) on delete cascade,
    version_number      int not null check (version_number > 0),
    amount              numeric(18,0) not null check (amount > 0),
    beneficiary_type    text not null check (beneficiary_type in ('internal','external')),
    beneficiary_user_id uuid references users(id),
    beneficiary_name    text,
    purpose             text not null,
    category            text not null,
    proposed_treasury   text not null
                            check (proposed_treasury in ('small_treasury','large_treasury')),
    project             text,
    urgency             text not null default 'normal'
                            check (urgency in ('low','normal','high','urgent')),
    desired_date        date,
    status              text not null default 'pending_first'
                            check (status in ('pending_first','pending_final',
                                              'approved','rejected',
                                              'correction_requested','superseded')),
    created_by          uuid not null references users(id),
    created_at          timestamptz not null default now(),
    constraint uq_version_number unique (request_id, version_number),
    -- internal => a user beneficiary; external => a free-text name (§6.1).
    constraint chk_beneficiary check (
        (beneficiary_type = 'internal'
            and beneficiary_user_id is not null and beneficiary_name is null)
     or (beneficiary_type = 'external'
            and beneficiary_name is not null and beneficiary_user_id is null)
    )
);

create index idx_versions_request on request_versions(request_id);
create index idx_versions_status on request_versions(status);

-- §13.1 rule 2: at most one APPROVED version per request.
create unique index uq_one_approved_version
    on request_versions(request_id) where status = 'approved';

-- At most one "live" (in-flight) version per request, so corrections supersede
-- cleanly and there is never more than one decision target at a time.
create unique index uq_one_live_version
    on request_versions(request_id)
    where status in ('pending_first','pending_final','correction_requested');

-- §6.3: only the status of a version may change; all business fields are frozen
-- (any other correction must be a new version).
create or replace function trg_version_immutable_fields()
returns trigger language plpgsql as $$
begin
    if row(new.request_id, new.version_number, new.amount, new.beneficiary_type,
           new.beneficiary_user_id, new.beneficiary_name, new.purpose,
           new.category, new.proposed_treasury, new.project, new.urgency,
           new.desired_date, new.created_by, new.created_at)
       is distinct from
       row(old.request_id, old.version_number, old.amount, old.beneficiary_type,
           old.beneficiary_user_id, old.beneficiary_name, old.purpose,
           old.category, old.proposed_treasury, old.project, old.urgency,
           old.desired_date, old.created_by, old.created_at)
    then
        raise exception
            'Only the status of a request version may change; create a new '
            'version for any other correction (§6.3).' using errcode = '23000';
    end if;
    return new;
end;
$$;

create trigger trg_versions_freeze_fields
    before update on request_versions
    for each row execute function trg_version_immutable_fields();

-- -----------------------------------------------------------------------------
-- request_validations — append-only record of every decision (§6.2). One first
-- and one final decision per version (unique). Comment mandatory unless approve.
-- is_self_decision flags the §4.1 transparency case (approver = requester).
-- -----------------------------------------------------------------------------
create table request_validations (
    id                 uuid primary key default gen_random_uuid(),
    request_version_id uuid not null references request_versions(id) on delete cascade,
    level              text not null check (level in ('first','final')),
    decision           text not null
                           check (decision in ('approved','not_approved',
                                               'correction_requested')),
    comment            text,
    is_self_decision   boolean not null default false,
    decided_by         uuid not null references users(id),
    decided_at         timestamptz not null default now(),
    constraint uq_one_decision_per_level unique (request_version_id, level),
    constraint chk_comment_required check (
        decision = 'approved' or (comment is not null and btrim(comment) <> '')
    )
);

create index idx_validations_version on request_validations(request_version_id);

create trigger trg_validations_immutable
    before update or delete on request_validations
    for each row execute function trg_block_modification();

-- -----------------------------------------------------------------------------
-- payments — exactly one per request (§13.1 rule 3), linked to the version that
-- was approved and carrying the same amount (rule 4), full amount only (§6.7).
--   * completed            — paid after approval (normal path)
--   * disbursed_pending    — Cashier advance, posted before approval (§6.5)
--   * disbursed_unapproved — that advance was subsequently refused; no refund
-- -----------------------------------------------------------------------------
create table payments (
    id                 uuid primary key default gen_random_uuid(),
    request_id         uuid not null unique references requests(id),
    request_version_id uuid not null references request_versions(id),
    treasury_account_id uuid not null references treasury_accounts(id),
    amount             numeric(18,0) not null check (amount > 0),
    movement_id        uuid not null references treasury_movements(id),
    is_advance         boolean not null default false,
    status             text not null
                           check (status in ('completed','disbursed_pending',
                                             'disbursed_unapproved')),
    paid_by            uuid not null references users(id),
    paid_at            timestamptz not null default now()
);

create index idx_payments_version on payments(request_version_id);

-- -----------------------------------------------------------------------------
-- request_overview — convenience read model: each request with its latest
-- version and current status. Honours the caller's RLS (security_invoker).
-- -----------------------------------------------------------------------------
create view request_overview
with (security_invoker = true) as
    select r.id              as request_id,
           r.reference,
           r.requester_id,
           r.created_at,
           v.id              as latest_version_id,
           v.version_number  as latest_version,
           v.amount,
           v.proposed_treasury,
           v.beneficiary_type,
           v.status
    from requests r
    join lateral (
        select * from request_versions rv
        where rv.request_id = r.id
        order by rv.version_number desc
        limit 1
    ) v on true;

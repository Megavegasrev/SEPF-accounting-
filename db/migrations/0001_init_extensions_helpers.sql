-- =============================================================================
-- SEPF Treasury — Foundation milestone
-- Migration 0001: Extensions and generic helpers
-- -----------------------------------------------------------------------------
-- Establishes the building blocks reused by every later migration:
--   * extensions (UUID generation, case-insensitive text)
--   * the "current application user" accessor used by row-level security
--   * a generic updated_at trigger
--   * a generic immutability guard used by the ledger and the audit log
-- Spec references: §13.1 (integrity), §14.1/§14.2 (server- and DB-side authz).
-- =============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists citext;      -- case-insensitive e-mail addresses

-- -----------------------------------------------------------------------------
-- Identity of the caller, as set by the backend on each transaction with:
--     SET LOCAL app.current_user_id = '<uuid>';
-- Returns NULL when unauthenticated. This is the single source of truth used by
-- RLS policies and SECURITY DEFINER functions, so that no privileged action can
-- rely on the UI alone (§14.2 "No sensitive permission relies solely on the UI").
-- If the project later adopts Supabase Auth, this can delegate to auth.uid().
-- -----------------------------------------------------------------------------
create or replace function app_current_user_id()
returns uuid
language sql
stable
as $$
    select nullif(current_setting('app.current_user_id', true), '')::uuid;
$$;

-- -----------------------------------------------------------------------------
-- Generic updated_at maintenance trigger.
-- -----------------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Generic immutability guard. Attached to append-only tables (the financial
-- ledger and the audit log) so that posted rows can never be edited or deleted
-- directly; corrections must go through an explicit reversal/adjustment.
-- Spec: §5.4 "Posted financial movements cannot be deleted or edited directly".
-- -----------------------------------------------------------------------------
create or replace function trg_block_modification()
returns trigger
language plpgsql
as $$
begin
    raise exception
        'Table % is append-only: % is not permitted (financial/audit integrity rule).',
        tg_table_name, lower(tg_op)
        using errcode = '23000';
end;
$$;

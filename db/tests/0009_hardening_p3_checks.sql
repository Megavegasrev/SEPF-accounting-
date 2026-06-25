-- =============================================================================
-- SEPF Treasury — Priority 3 hardening checks (database security)
--   psql -d sepf -f db/tests/0009_hardening_p3_checks.sql
-- "EXPECT FAIL" lines must raise; "EXPECT t" lines must print t.
-- =============================================================================
\set ON_ERROR_STOP 0
\pset pager off
\set super '''11111111-1111-1111-1111-111111111111'''
\set ops   '''33333333-3333-3333-3333-333333333333'''

\echo '\n################ 11. EXECUTE locked down (PUBLIC revoked, role-scoped) ######'
reset role;
select 'business fn / PUBLIC (EXPECT f): '
     || has_function_privilege('public','declare_capital_contribution(numeric)','execute');
select 'business fn / app_user (EXPECT t): '
     || has_function_privilege('app_user','declare_capital_contribution(numeric)','execute');
select 'internal post fn / app_user (EXPECT f): '
     || has_function_privilege('app_user','post_treasury_movement(uuid,numeric,text,text,uuid,text,uuid,uuid,uuid,text,text,jsonb)','execute');
select 'admin fn / app_user (EXPECT t): '
     || has_function_privilege('app_user','admin_set_setting(text,jsonb,text)','execute');
select 'citext op / PUBLIC kept (EXPECT t): '
     || has_function_privilege('public','citext_eq(citext,citext)','execute');

\echo '\n################ 9/10. No direct writes to admin/auth tables as app_user #####'
set role app_user; select set_config('app.current_user_id', :super, false);
\echo '-- EXPECT FAIL: app_user inserts a login_event directly'
insert into login_events (email_attempted, event) values ('x@y.z', 'login_failure');
\echo '-- EXPECT FAIL: app_user updates a user row directly (no write policy)'
update users set full_name = 'hacked' where id = :ops;
\echo '-- EXPECT FAIL: app_user inserts a setting directly (no write policy)'
insert into settings (key, value) values ('rogue', '1'::jsonb);
\echo '-- EXPECT FAIL: app_user grants a role_permission directly (no write policy)'
insert into role_permissions (role_id, permission_id)
  select (select id from roles limit 1), (select id from permissions limit 1);
reset role;
\echo '-- EXPECT FAIL: app_user updates a session directly (broad policy dropped)'
insert into sessions (user_id, token_hash, expires_at) values (:ops, 'h-direct', now() + interval '1h');
set role app_user; select set_config('app.current_user_id', :ops, false);
update sessions set revoked_at = now() where token_hash = 'h-direct';
reset role;

\echo '\n################ 10. Admin functions: permission-gated and audited #########'
\echo '-- EXPECT FAIL: Operations Director (no settings.manage) sets a setting'
set role app_user; select set_config('app.current_user_id', :ops, false);
select admin_set_setting('feature.x', 'true'::jsonb);
\echo '-- OK: Super Admin (users.manage) suspends a user, then status is suspended'
select set_config('app.current_user_id', :super, false);
select (admin_set_user_status(:ops, 'suspended')).status as new_status;
reset role;
select 'suspend persisted (EXPECT t): ' || (status = 'suspended') from users where id = :ops;

\echo '\n################ 8. revoke_session only flips revoked_at ####################'
reset role;
insert into sessions (user_id, token_hash, expires_at) values (:super, 'h-revoke', now() + interval '1h');
select revoke_session('h-revoke');
select 'session revoked (EXPECT t): ' || (revoked_at is not null) from sessions where token_hash = 'h-revoke';

\echo '\n################ 12. All views queryable under app_user (RLS, no errors) ####'
set role app_user; select set_config('app.current_user_id', :super, false);
-- count(*) >= 0 is always true; it succeeds only if the view is readable under
-- this role (a permission/grant problem would raise instead).
select 'views ok (EXPECT t): ' || bool_and(ok) from (
  select (select count(*) >= 0 from treasury_balances)              as ok union all
  select (select count(*) >= 0 from treasury_consolidated)          union all
  select (select count(*) >= 0 from request_overview)               union all
  select (select count(*) >= 0 from payment_control_status)         union all
  select (select count(*) >= 0 from salary_cycle_summary)           union all
  select (select count(*) >= 0 from shareholder_capital_summary)    union all
  select (select count(*) >= 0 from asset_register)                 union all
  select (select count(*) >= 0 from loan_summary)                   union all
  select (select count(*) >= 0 from borrowing_summary)              union all
  select (select count(*) >= 0 from borrowing_installment_schedule) union all
  select (select count(*) >= 0 from v_transaction_history)
) v;
reset role;

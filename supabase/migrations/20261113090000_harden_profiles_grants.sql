-- CricEco · migration 10 · least-privilege grants on public.profiles
-- (Stage 4.3.7, additive: privileges only)
--
-- public.profiles existed before these migrations and still carries
-- Supabase's default grants: every privilege for anon and authenticated —
-- including TRUNCATE (which row level security does not cover), DELETE,
-- REFERENCES, TRIGGER and, on PostgreSQL 17, MAINTAIN (VACUUM / ANALYZE /
-- REINDEX / CLUSTER …). Every table created by migrations 2–8 already starts from
-- "revoke all from anon, authenticated"; this brings profiles in line.
--
-- After this migration:
--   * anon: no privilege on profiles (it has no policy either, so the API
--     already returned nothing; a signed-out request now gets 42501);
--   * authenticated: exactly SELECT, INSERT, UPDATE — what the own-row
--     policies allow and what is used: the app's reads and its direct role
--     update, save_profile_setup v1 / v2 (SECURITY INVOKER: insert … on
--     conflict do update), update_profile_details (migration 9: its FOR NO
--     KEY UPDATE locks need UPDATE), and the club-owner role trigger;
--   * PUBLIC: no privilege on profiles (normally none already);
--   * no column-level grants on profiles for anon / authenticated / PUBLIC
--     (revoking a table privilege revokes the column privileges with it).
-- Not closed by this (by design): LOCK TABLE — PostgreSQL allows it with
-- UPDATE, which authenticated needs; it is plain SQL, which the API (PostgREST)
-- never sends, and these roles cannot log in.
-- Not changed: the table, its rows, columns, constraints, indexes, RLS
-- (enabled, not forced), policies, triggers, functions, and every other
-- role's grants — service_role and postgres included (checked below). The
-- sign-up trigger (handle_new_user, SECURITY DEFINER) and the auth.users →
-- profiles cascade need no anon / authenticated privilege.
--
-- Independent of migrations 6–9 (needs only migration 1): it may be applied
-- before them — the approved production order is migration 10 FIRST, then
-- 6 → D1 → 7 → 8 → 9. It supersedes section B of
-- review/20261027090400_profiles_hardening_REVIEW.sql (which would then
-- change nothing).
--
-- The post-check is what makes this safe to run: REVOKE only removes the
-- grants made by the role running it (the table owner), so a grant made by
-- another role would survive silently. If anything other than exactly the
-- intended privileges remains, the migration raises and — inside the
-- transaction — nothing is changed.
--
-- RUN INSIDE ONE TRANSACTION (begin; set local lock_timeout = '5s'; … commit;)
-- as the table owner (the SQL Editor's postgres role). In the SQL Editor
-- the first error aborts the transaction; with psql, use -v ON_ERROR_STOP=1.
-- Run tests/00h_preflight_profiles_grants.sql first and KEEP its output: it
-- is the exact record of the current grants.
-- NOT APPLIED. Rollback: rollback/20261113_rollback_profiles_grants.sql.

-- ---------------------------------------------------------------------------
-- Guard: the table and its row level security as expected; the grants of
-- every role other than anon / authenticated / PUBLIC recorded for the
-- post-check (transaction-local setting).
-- ---------------------------------------------------------------------------
do $$
declare
  t constant regclass := to_regclass('public.profiles');
begin
  if t is null then
    raise exception 'migration 10: public.profiles does not exist — nothing changed';
  end if;
  if (select relkind from pg_class where oid = t) <> 'r' then
    raise exception 'migration 10: public.profiles is not a table — nothing changed';
  end if;
  if to_regrole('anon') is null or to_regrole('authenticated') is null then
    raise exception 'migration 10: the anon / authenticated roles are missing — nothing changed';
  end if;
  if not (select relrowsecurity from pg_class where oid = t) then
    raise exception 'migration 10: row level security is not enabled on profiles — nothing changed';
  end if;
  -- The own-row policies for signed-in users (whatever their names).
  if (select count(distinct p.polcmd) from pg_policy p
       where p.polrelid = t and p.polcmd in ('r', 'a', 'w')
         and (0::oid = any (p.polroles) or to_regrole('authenticated') = any (p.polroles))) <> 3 then
    raise exception 'migration 10: the SELECT / INSERT / UPDATE policies for authenticated are not all there — nothing changed';
  end if;
  if not pg_has_role(current_user, (select relowner from pg_class where oid = t), 'usage') then
    raise exception 'migration 10: run as the owner of public.profiles (%), not as % — nothing changed',
      (select relowner::regrole from pg_class where oid = t), current_user;
  end if;
  perform set_config('criceco.m10_other_grants',
    coalesce((select string_agg(g, ',' order by g)
                from (select format('%s/%s/%s/%s', a.grantee::regrole, a.grantor::regrole,
                                    a.privilege_type, a.is_grantable) as g
                        from aclexplode((select relacl from pg_class where oid = t)) a
                       where a.grantee <> 0
                         and a.grantee not in (to_regrole('anon'), to_regrole('authenticated'))) s), ''),
    true);
end $$;

-- ---------------------------------------------------------------------------
-- The change.
-- ---------------------------------------------------------------------------
revoke all on table public.profiles from public, anon;
revoke all on table public.profiles from authenticated;
grant select, insert, update on table public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Post-check (same transaction): effective privileges — has_table_privilege
-- counts PUBLIC and inherited grants — exactly as intended; no column-level
-- grant left; every other role's grants exactly as before. Otherwise raise:
-- the whole migration is rolled back when it runs inside one transaction, as
-- required above (without one, the REVOKE / GRANT may already be committed).
-- ---------------------------------------------------------------------------
do $$
declare
  t constant regclass := 'public.profiles'::regclass;
  privs text[] := array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'];
  p text;
  other text;
begin
  if current_setting('server_version_num')::int >= 170000 then
    privs := array_append(privs, 'MAINTAIN');
  end if;
  foreach p in array privs loop
    if has_table_privilege('anon', t, p) then
      raise exception 'migration 10: anon still holds % on profiles (a grant this role cannot revoke?) — privilege verification failed; the change is undone only if this ran inside one transaction (begin; … commit;)', p;
    end if;
    if has_table_privilege('public', t, p) then
      raise exception 'migration 10: PUBLIC still holds % on profiles — privilege verification failed; the change is undone only if this ran inside one transaction (begin; … commit;)', p;
    end if;
    if has_table_privilege('authenticated', t, p) <> (p in ('SELECT', 'INSERT', 'UPDATE')) then
      raise exception 'migration 10: authenticated % on profiles is %, not as intended — privilege verification failed; the change is undone only if this ran inside one transaction (begin; … commit;)',
        p, case when has_table_privilege('authenticated', t, p) then 'still granted' else 'missing' end;
    end if;
  end loop;
  if exists (select 1 from pg_attribute a, aclexplode(a.attacl) x
              where a.attrelid = t and a.attnum > 0 and not a.attisdropped
                and (x.grantee = 0 or x.grantee in (to_regrole('anon'), to_regrole('authenticated')))) then
    raise exception 'migration 10: a column-level grant on profiles is left for anon / authenticated / PUBLIC — privilege verification failed; the change is undone only if this ran inside one transaction (begin; … commit;)';
  end if;
  if exists (select 1 from aclexplode((select relacl from pg_class where oid = t)) x
              where x.grantee = to_regrole('authenticated') and x.is_grantable) then
    raise exception 'migration 10: authenticated holds a grant option on profiles — privilege verification failed; the change is undone only if this ran inside one transaction (begin; … commit;)';
  end if;
  select coalesce(string_agg(g, ',' order by g), '')
    into other
    from (select format('%s/%s/%s/%s', a.grantee::regrole, a.grantor::regrole,
                        a.privilege_type, a.is_grantable) as g
            from aclexplode((select relacl from pg_class where oid = t)) a
           where a.grantee <> 0
             and a.grantee not in (to_regrole('anon'), to_regrole('authenticated'))) s;
  if other is distinct from current_setting('criceco.m10_other_grants') then
    raise exception 'migration 10: another role''s grants on profiles changed (service_role / postgres must be unchanged) — privilege verification failed; the change is undone only if this ran inside one transaction (begin; … commit;)';
  end if;
end $$;

notify pgrst, 'reload schema';

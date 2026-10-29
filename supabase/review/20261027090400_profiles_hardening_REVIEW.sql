-- CricEco · migration 5 · profiles hardening — REVIEW REQUIRED, NOT PART OF 1–4.
--
-- Changes rules / permissions on the EXISTING profiles table. No data is
-- changed or deleted. Apply only after migrations 1–4 and after reviewing
-- each section. The guard below aborts the whole script: remove it
-- deliberately once reviewed.
--
-- Live findings this is based on (00b inspection):
--   5 rows · 4 completed · 1 without full_name · 1 without phone ·
--   4 phones in 03XXXXXXXXX form, 0 in +923XXXXXXXXX ·
--   roles: 3 club_owner, 1 player, 1 NULL ·
--   profiles_id_fkey already ON DELETE CASCADE (nothing to do there) ·
--   own-row INSERT / SELECT / UPDATE policies for authenticated (kept) ·
--   anon / authenticated / service_role hold every table privilege (section B).

do $$
begin
  raise exception 'REVIEW ONLY: read supabase/README.md, then remove this guard to apply';
end $$;

-- ---------------------------------------------------------------------------
-- A. Field rules on existing columns — never blocking a legacy row.
--    Each rule is added ONLY if every existing row already meets it, and is
--    then fully validated; otherwise it is skipped with a NOTICE (nothing
--    half-applied). So no existing row can become impossible to edit.
--    The phone rule accepts every Pakistani mobile spelling the app has
--    stored (03XXXXXXXXX, 0300-1234567, 0300 1234567, 923…, +923…): the 4
--    legacy "03" phones stay valid as they are. save_profile_setup() writes
--    the canonical +923XXXXXXXXX form; old values change only when their
--    owner saves Profile Setup again.
-- ---------------------------------------------------------------------------
do $$
declare
  n int;
begin
  select count(*) into n from public.profiles
   where full_name is not null and char_length(btrim(full_name)) not between 2 and 100;
  if n = 0 then
    alter table public.profiles add constraint profiles_full_name_check
      check (full_name is null or char_length(btrim(full_name)) between 2 and 100);
    raise notice 'A: profiles_full_name_check added (all rows already comply)';
  else
    raise notice 'A: profiles_full_name_check SKIPPED — % existing row(s) would violate it', n;
  end if;

  select count(*) into n from public.profiles
   where phone is not null and regexp_replace(phone, '[\s-]', '', 'g') !~ '^(\+92|92|0)3[0-9]{9}$';
  if n = 0 then
    alter table public.profiles add constraint profiles_phone_check
      check (phone is null or regexp_replace(phone, '[\s-]', '', 'g') ~ '^(\+92|92|0)3[0-9]{9}$');
    raise notice 'A: profiles_phone_check added (all rows already comply)';
  else
    raise notice 'A: profiles_phone_check SKIPPED — % existing row(s) would violate it', n;
  end if;

  select count(*) into n from public.profiles
   where role is not null and role not in ('player', 'club_owner');
  if n = 0 then
    alter table public.profiles add constraint profiles_role_check
      check (role is null or role in ('player', 'club_owner'));
    raise notice 'A: profiles_role_check added (all rows already comply)';
  else
    raise notice 'A: profiles_role_check SKIPPED — % existing row(s) would violate it', n;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- B. Least-privilege grants. Today every API role holds every privilege on
--    profiles. RLS already limits SELECT / INSERT / UPDATE / DELETE to the
--    signed-in owner's row (and gives anon nothing), but TRUNCATE is not
--    covered by RLS. Removes: all anon access; DELETE / TRUNCATE /
--    REFERENCES / TRIGGER for authenticated. Keeps SELECT / INSERT / UPDATE
--    for authenticated (what the policies allow). service_role unchanged.
--    Rows are unaffected. Matches the grants on the 3 new tables.
-- ---------------------------------------------------------------------------
revoke all on table public.profiles from anon;
revoke delete, truncate, references, trigger on table public.profiles from authenticated;
grant select, insert, update on table public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- C. Policies — nothing to do: the existing own-row INSERT / SELECT / UPDATE
--    policies for authenticated are kept as they are (no DELETE policy).
-- D. Foreign key — nothing to do: profiles_id_fkey is already
--    ON DELETE CASCADE.
-- ---------------------------------------------------------------------------

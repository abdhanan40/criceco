-- CricEco · migration 9 · update_profile_details() (Stage 4.3.6a, additive only)
-- Edit Profile's save in ONE transaction: the profile details (full name,
-- phone, date of birth) and the existing current / permanent address rows
-- are written together or not at all. Before this, the app wrote them in
-- separate requests, so a refused city id (or a lost connection) after the
-- name was written left a partial save.
--
-- How it works (as the signed-in caller — SECURITY INVOKER, RLS applies):
--   1. reads the caller's stored profile and address rows and LOCKS them
--      (FOR NO KEY UPDATE, in the order profile → current → permanent, as
--      save_profile_setup writes them), so a concurrent save waits and the
--      comparison below is made against the latest committed values;
--   2. works out what differs from them, and checks ONLY what changed —
--      exactly as the app did field by field (an unchanged legacy phone or
--      name is never re-checked or rewritten); every check runs before the
--      first write, and any error rolls the whole call back;
--   3. writes only the changed columns / rows, so unchanged rows keep their
--      last_updated_at.
-- Rules:
--   * full name 2–100 characters (it can't be cleared); phone a Pakistani
--     mobile number stored as +923XXXXXXXXX (v1's spellings), or blank = no
--     phone (Edit Profile may clear it; dashes alone are refused). The
--     stored phone is compared in the same canonical form, so a stored
--     value sent back unchanged — another spelling, or one today's rule
--     refuses — never blocks a save and is never rewritten; date of
--     birth 1900-01-01 up to today, or NULL = cleared (approved: a completed
--     profile may clear it, as the table already allowed);
--   * an address is written only if its row already exists (Profile Setup
--     creates the rows); all four address arguments NULL = leave it alone;
--   * a supplied city id always wins: the row gets that city's plain name,
--     whatever text came with it (written as city_id + name; migration 8's
--     sync keeps them in step). A NEWLY picked id must be an ACTIVE city; the
--     id the row already has is kept even if its city was deactivated since.
--     Without an id, only the text is written and migration 8 keeps or
--     re-resolves the stored id;
--   * "same as current" is the STORED profiles.permanent_same_as_current:
--     the existing permanent row then becomes a copy of the current row as
--     stored after this save — exactly its city id (picked, kept or
--     re-resolved; also NULL), its Area and Address, and its text (the
--     city's plain name instead when migration 8 would not keep that text
--     with that id, e.g. an alias of a city deactivated since); rows
--     already in step are not written (the permanent arguments are ignored; a
--     permanent row that drifted from the current one is brought back in
--     step, on the id and the text-only path alike, never refused for it); a
--     separate permanent address uses the permanent arguments;
--   * the caller's profile row must exist (the sign-up trigger creates it);
--   * never changes profile_completed, role, permanent_same_as_current or
--     anyone else's rows.
-- Refusals:
--   * 42501 'not authenticated' — no signed-in user (as v1 / v2);
--   * P0002 'profile not found' — no profile row for the signed-in user
--     (nothing is written; the app shows its generic "couldn't save");
--   * 23514 for every value check, with the messages the app already maps
--     (save_profile_setup v1 / v2 texts; address checks name their
--     constraint).
-- Nothing existing is modified: no table, column, constraint, policy, grant,
-- trigger or function of migrations 1–8 changes.
--
-- Depends on migration 8 (address city_id + its sync triggers) and so on
-- migration 6 (public.cities).
-- RUN INSIDE ONE TRANSACTION (begin; set local lock_timeout = '5s'; … commit;).
-- The guard below then stops everything: in the SQL Editor the first error
-- aborts the transaction (nothing after it runs or commits); with psql, run
-- with -v ON_ERROR_STOP=1 (psql meta-commands like \set are not used here —
-- the SQL Editor would reject them).
-- NOT APPLIED. Rollback: rollback/20261111_rollback_update_profile_details.sql.

do $$
begin
  if to_regclass('public.cities') is null
     or (select count(*) from information_schema.columns
          where table_schema = 'public' and column_name = 'city_id'
            and table_name in ('current_addresses', 'permanent_addresses')) <> 2
     or to_regprocedure('public.address_city_sync_from_id()') is null then
    raise exception 'migration 9: migration 8 (address city_id) is required';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'update_profile_details') then
    raise exception 'migration 9: update_profile_details already exists — nothing changed';
  end if;
end $$;

create function public.update_profile_details(
  p_full_name         text,
  p_phone             text,
  p_date_of_birth     date,
  p_current_city      text,
  p_current_city_id   integer,
  p_current_area      text,
  p_current_address   text,
  p_permanent_city    text    default null,
  p_permanent_city_id integer default null,
  p_permanent_area    text    default null,
  p_permanent_address text    default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  -- The phone sent and the phone stored, both in ONE canonical form (step 2a).
  v_phone    text;
  v_old_norm text;
  v_raw      text;
  v_digits   text;
  v_norm     text;
  v_name text := btrim(p_full_name);

  -- Stored profile.
  v_found     boolean := false;
  v_old_name  text;
  v_old_phone text;
  v_old_dob   date;
  v_same      boolean;
  v_set_name  boolean := false;
  v_set_phone boolean := false;
  v_set_dob   boolean := false;

  -- Current address: stored row, wanted values, write?
  c_found boolean := false;
  c_old_city text; c_old_id integer; c_old_area text; c_old_address text;
  c_city text; c_id integer; c_area text; c_address text;
  c_new   boolean := false;  -- a newly picked city id
  c_write boolean := false;

  -- Permanent address: its arguments (the current ones when "same as
  -- current"), stored row, wanted values, write?
  a_city text; a_id integer; a_area text; a_address text;
  m_copy boolean := false;  -- "same as current": copy the stored current row
  f_id integer; f_city text; f_area text; f_address text;  -- that row, as stored
  f_text text;  -- the text the copy gets
  m_found boolean := false;
  m_old_city text; m_old_id integer; m_old_area text; m_old_address text;
  q_city text; q_id integer; q_area text; q_address text;
  q_new   boolean := false;
  q_write boolean := false;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- 1. What is stored (own rows only: RLS), locked until the end of the
  -- transaction (FOR NO KEY UPDATE — the lock an UPDATE of these columns
  -- takes): a concurrent save of the same rows waits, and these values are
  -- the latest committed ones. A foreign-key check on the profile (FOR KEY
  -- SHARE: inserting a player profile or a user role) is not blocked.
  -- Creating a club MAY wait: its trigger sets profiles.role to 'club_owner'
  -- only where the role is NULL or 'player'; for such a profile that update
  -- waits until this save ends (no deadlock: the club insert holds only its
  -- new club row and a FOR KEY SHARE on the profile, neither of which this
  -- function needs). For a profile already 'club_owner' nothing waits.
  -- Lock order: profile → current → permanent, as v1 / v2 write.
  select true, pr.full_name, pr.phone, pr.date_of_birth, coalesce(pr.permanent_same_as_current, true)
    into v_found, v_old_name, v_old_phone, v_old_dob, v_same
    from public.profiles pr where pr.id = v_uid
     for no key update;
  if not coalesce(v_found, false) then
    raise exception 'profile not found' using errcode = 'P0002';
  end if;
  v_same := coalesce(v_same, true);
  select true, ca.city, ca.city_id, ca.area, ca.address
    into c_found, c_old_city, c_old_id, c_old_area, c_old_address
    from public.current_addresses ca where ca.user_id = v_uid
     for no key update;
  c_found := coalesce(c_found, false);
  select true, pa.city, pa.city_id, pa.area, pa.address
    into m_found, m_old_city, m_old_id, m_old_area, m_old_address
    from public.permanent_addresses pa where pa.user_id = v_uid
     for no key update;
  m_found := coalesce(m_found, false);

  -- 2a. Profile details: checked only when changed.
  -- Phone: the sent and the stored value go through the SAME normalisation
  -- (v1's spellings: spaces / dashes dropped, a leading 0 or 92 → +92;
  -- blank — empty or only whitespace — = no phone; anything else that is not
  -- a number, e.g. dashes alone, is kept with its whitespace removed, so
  -- "- -" and "--" are the same value). So a legacy spelling of
  -- the stored number, or a stored value today's rule refuses, sent back
  -- unchanged is no change; a blank phone clears a stored one (also a stored
  -- blank value); a new invalid value is refused below.
  for i in 1 .. 2 loop
    v_raw := case i when 1 then p_phone else v_old_phone end;
    v_digits := regexp_replace(coalesce(v_raw, ''), '[\s-]', '', 'g');
    v_norm := case
      when v_digits ~ '^03[0-9]{9}$'  then '+92' || substr(v_digits, 2)
      when v_digits ~ '^923[0-9]{9}$' then '+' || v_digits
      when v_digits = '' and regexp_replace(coalesce(v_raw, ''), '\s', '', 'g') <> ''
        then regexp_replace(v_raw, '\s', '', 'g')  -- no digits: whitespace removed ("- -" = "--")
      else nullif(v_digits, '')
    end;
    if i = 1 then v_phone := v_norm; else v_old_norm := v_norm; end if;
  end loop;
  v_set_name := v_name is distinct from btrim(v_old_name);
  -- A stored blank value (no phone in canonical form, yet not NULL) is
  -- cleared to NULL by a blank / NULL phone that differs from it.
  v_set_phone := v_phone is distinct from v_old_norm
    or (v_phone is null and v_old_phone is not null and p_phone is distinct from v_old_phone);
  v_set_dob := p_date_of_birth is distinct from v_old_dob;
  if v_set_name and (v_name is null or char_length(v_name) not between 2 and 100) then
    raise exception 'full_name must be 2–100 characters' using errcode = '23514';
  end if;
  if v_set_phone and v_phone is not null and v_phone !~ '^\+923[0-9]{9}$' then
    raise exception 'phone must be a Pakistani mobile number' using errcode = '23514';
  end if;
  if v_set_dob and p_date_of_birth is not null then
    if p_date_of_birth < date '1900-01-01' then
      raise exception 'date_of_birth is required (1900 or later)' using errcode = '23514';
    end if;
    if p_date_of_birth > current_date then
      raise exception 'date_of_birth cannot be in the future' using errcode = '23514';
    end if;
  end if;

  -- 2b. Current address (an existing row, and some argument given).
  -- A supplied city id always wins: the row gets that city's plain name,
  -- whatever text came with it. Only a NEWLY picked id must be an active
  -- city; the id the row already has is kept even if that city was
  -- deactivated since (an unrelated save is never blocked by it).
  if c_found and num_nonnulls(p_current_city, p_current_city_id, p_current_area, p_current_address) > 0 then
    c_area := btrim(p_current_area);
    c_address := btrim(p_current_address);
    if p_current_city_id is not null then
      c_new := p_current_city_id is distinct from c_old_id;
      select ci.name into c_city from public.cities ci
       where ci.id = p_current_city_id and (ci.is_active or not c_new);
      if c_city is null then
        raise exception 'current_city_id must be an active city' using errcode = '23514';
      end if;
      c_id := p_current_city_id;
    else
      c_city := btrim(p_current_city);
    end if;
    c_write := c_new
      or (c_city, c_area, c_address) is distinct from (btrim(c_old_city), btrim(c_old_area), btrim(c_old_address));
    if c_write then
      if c_city is null or char_length(c_city) not between 1 and 100 then
        raise exception 'current_addresses.city must be 1–100 characters (constraint "current_addresses_city_check")'
          using errcode = '23514';
      end if;
      if c_area is null or char_length(c_area) not between 1 and 150 then
        raise exception 'current_addresses.area must be 1–150 characters (constraint "current_addresses_area_check")'
          using errcode = '23514';
      end if;
      if c_address is null or char_length(c_address) not between 1 and 500 then
        raise exception 'current_addresses.address must be 1–500 characters (constraint "current_addresses_address_check")'
          using errcode = '23514';
      end if;
    end if;
  end if;

  -- 2c. Permanent address.
  -- "Same as current" (stored flag) with a current row: the permanent row
  -- becomes a copy of the current row AS STORED once step 3 has written it —
  -- its city id (newly picked, kept, or re-resolved by migration 8 on the
  -- text-only path), its text, Area and Address. Nothing in that copy needs
  -- checking: every value is the current row's own (checked above, or
  -- already stored). A permanent row that drifted from the current one is
  -- brought back in step — never a reason to refuse. All four current
  -- arguments NULL = both addresses left alone.
  -- Otherwise ("No", or no current row): the permanent arguments ("same as
  -- current" without a current row: the current arguments), under the
  -- current address's rules.
  if v_same and c_found then
    m_copy := m_found and num_nonnulls(p_current_city, p_current_city_id, p_current_area, p_current_address) > 0;
  elsif v_same then
    a_city := p_current_city; a_id := p_current_city_id;
    a_area := p_current_area; a_address := p_current_address;
  else
    a_city := p_permanent_city; a_id := p_permanent_city_id;
    a_area := p_permanent_area; a_address := p_permanent_address;
  end if;
  if not (v_same and c_found) and m_found and num_nonnulls(a_city, a_id, a_area, a_address) > 0 then
    q_area := btrim(a_area);
    q_address := btrim(a_address);
    if a_id is not null then
      q_new := a_id is distinct from m_old_id;
      select ci.name into q_city from public.cities ci
       where ci.id = a_id and (ci.is_active or not q_new);
      if q_city is null then
        raise exception 'permanent_city_id must be an active city' using errcode = '23514';
      end if;
      q_id := a_id;
    else
      q_city := btrim(a_city);
    end if;
    q_write := q_new
      or (q_city, q_area, q_address) is distinct from (btrim(m_old_city), btrim(m_old_area), btrim(m_old_address));
    if q_write then
      if q_city is null or char_length(q_city) not between 1 and 100 then
        raise exception 'permanent_addresses.city must be 1–100 characters (constraint "permanent_addresses_city_check")'
          using errcode = '23514';
      end if;
      if q_area is null or char_length(q_area) not between 1 and 150 then
        raise exception 'permanent_addresses.area must be 1–150 characters (constraint "permanent_addresses_area_check")'
          using errcode = '23514';
      end if;
      if q_address is null or char_length(q_address) not between 1 and 500 then
        raise exception 'permanent_addresses.address must be 1–500 characters (constraint "permanent_addresses_address_check")'
          using errcode = '23514';
      end if;
    end if;
  end if;

  -- 3. Writes — only what changed; all checks have passed.
  -- Profile: one statement per changed column, so an unchanged column is
  -- never in the SET list (no trigger sees it written).
  if v_set_name then
    update public.profiles set full_name = v_name where id = v_uid;
  end if;
  if v_set_phone then
    update public.profiles set phone = v_phone where id = v_uid;
  end if;
  if v_set_dob then
    update public.profiles set date_of_birth = p_date_of_birth where id = v_uid;
  end if;

  -- Addresses: a new id is written with the city's name (migration 8: the id
  -- wins); otherwise the text only (migration 8 keeps or re-resolves the id).
  if c_write then
    if c_id is not null then
      update public.current_addresses
         set city_id = c_id, city = c_city, area = c_area, address = c_address
       where user_id = v_uid;
    else
      update public.current_addresses
         set city = c_city, area = c_area, address = c_address
       where user_id = v_uid;
    end if;
  end if;
  if q_write then
    if q_id is not null then
      update public.permanent_addresses
         set city_id = q_id, city = q_city, area = q_area, address = q_address
       where user_id = v_uid;
    else
      update public.permanent_addresses
         set city = q_city, area = q_area, address = q_address
       where user_id = v_uid;
    end if;
  end if;

  -- "Same as current": the permanent row takes the current row as stored
  -- now (step 2c) — EXACTLY its city id (also NULL), its Area and Address,
  -- and its text where migration 8 lets a row keep that text with that id.
  if m_copy then
    select ca.city_id, ca.city, ca.area, ca.address
      into f_id, f_city, f_area, f_address
      from public.current_addresses ca where ca.user_id = v_uid;
    -- The copy's text. Migration 8 keeps an id with a text only while the
    -- text names that city (its name, its "Name (Qualifier)" label, or text
    -- that resolves to it among ACTIVE cities — the same test as
    -- address_city_sync_from_text). If the current row's text no longer does
    -- (e.g. an alias of a city deactivated since), the copy gets the city's
    -- plain name: the text migration 8 gives a row whose id is written alone.
    f_text := f_city;
    if f_id is not null then
      select case
               when public.location_search_key(f_city) = ci.search_key
                 or public.location_search_key(f_city) = ci.search_key || ' ' || public.location_search_key(ci.qualifier)
                 or public.resolve_city_id(f_city) = ci.id
               then f_city
               else ci.name
             end
        into f_text
        from public.cities ci where ci.id = f_id;
    end if;
    -- Rows already in step are not written at all.
    if (m_old_id, m_old_city, m_old_area, m_old_address) is distinct from (f_id, f_text, f_area, f_address) then
      if f_id is not null and f_text is distinct from f_city then
        -- The id alone, with Area and Address: migration 8 sets the plain name.
        update public.permanent_addresses
           set city_id = f_id, area = f_area, address = f_address
         where user_id = v_uid;
      else
        -- 1. The id (migration 8 sets that city's plain name; NULL keeps the text).
        if f_id is distinct from m_old_id then
          update public.permanent_addresses set city_id = f_id where user_id = v_uid;
        end if;
        -- 2. The text, Area and Address (migration 8 keeps the id: the text names that city).
        select pa.city, pa.area, pa.address into m_old_city, m_old_area, m_old_address
          from public.permanent_addresses pa where pa.user_id = v_uid;
        if (f_text, f_area, f_address) is distinct from (m_old_city, m_old_area, m_old_address) then
          update public.permanent_addresses
             set city = f_text, area = f_area, address = f_address
           where user_id = v_uid;
        end if;
      end if;
      -- 3. Exactly the current row's id, whatever migration 8 re-resolved
      --    from the text (e.g. the current id is NULL but the text now
      --    resolves): written alone, migration 8 keeps it and the text.
      select pa.city_id into m_old_id from public.permanent_addresses pa where pa.user_id = v_uid;
      if m_old_id is distinct from f_id then
        update public.permanent_addresses set city_id = f_id where user_id = v_uid;
      end if;
    end if;
  end if;
end;
$$;

comment on function public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text) is
  'Edit Profile: the profile details and the existing address rows in one transaction (only changed values are checked and written).';

-- ---------------------------------------------------------------------------
-- Privileges: signed-in users only. Table grants and RLS are unchanged (the
-- function runs as the caller).
-- ---------------------------------------------------------------------------
revoke execute on function public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text)
  from public, anon;
grant execute on function public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text)
  to authenticated;

notify pgrst, 'reload schema';

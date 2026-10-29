-- CricEco · migration 4/4 · save_profile_setup()
-- User Profile Setup writes three tables (profiles, current_addresses,
-- permanent_addresses). Done from the app as three calls, a dropped
-- connection could leave a half-saved profile. This function saves all of
-- it in one transaction.
--
-- SECURITY INVOKER: it runs as the signed-in user, so the RLS policies on
-- profiles (the existing "own row" ones) and the address tables still apply:
-- a user can only ever write their own rows.
-- It validates name and phone itself, because the matching CHECK
-- constraints on the existing profiles columns are only in the review
-- migration. Any failure (e.g. a missing permanent address under "No")
-- rolls the whole save back.
--
-- NOT APPLIED. Requires migrations 1–2.

create or replace function public.save_profile_setup(
  p_full_name                 text,
  p_phone                     text,
  p_date_of_birth             date,
  p_current_city              text,
  p_current_area              text,
  p_current_address           text,
  p_permanent_same_as_current boolean,
  p_permanent_city            text default null,
  p_permanent_area            text default null,
  p_permanent_address         text default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_same  boolean := coalesce(p_permanent_same_as_current, true);
  -- The app shows "0312 9020000"; saves store +923XXXXXXXXX.
  -- Spaces / dashes are dropped and a leading 0 or 92 becomes +92; anything
  -- else fails the phone check below.
  v_digits text := regexp_replace(coalesce(p_phone, ''), '[\s-]', '', 'g');
  v_phone  text := case
    when v_digits ~ '^03[0-9]{9}$'    then '+92' || substr(v_digits, 2)
    when v_digits ~ '^923[0-9]{9}$'   then '+' || v_digits
    else nullif(v_digits, '')
  end;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_full_name is null or char_length(btrim(p_full_name)) not between 2 and 100 then
    raise exception 'full_name must be 2–100 characters' using errcode = '23514';
  end if;
  if v_phone is null or v_phone !~ '^\+923[0-9]{9}$' then
    raise exception 'phone must be a Pakistani mobile number' using errcode = '23514';
  end if;
  if p_date_of_birth is null or p_date_of_birth < date '1900-01-01' then
    raise exception 'date_of_birth is required (1900 or later)' using errcode = '23514';
  end if;

  -- 1. Profile details. Writes only the caller's row (id = auth.uid(); RLS).
  --    profile_completed is set last, once both addresses exist (step 4).
  insert into public.profiles (id, full_name, phone, date_of_birth, permanent_same_as_current)
  values (v_uid, btrim(p_full_name), v_phone, p_date_of_birth, v_same)
  on conflict (id) do update set
    full_name                 = excluded.full_name,
    phone                     = excluded.phone,
    date_of_birth             = excluded.date_of_birth,
    permanent_same_as_current = excluded.permanent_same_as_current;

  -- 2. Current address.
  insert into public.current_addresses (user_id, city, area, address)
  values (v_uid, btrim(p_current_city), btrim(p_current_area), btrim(p_current_address))
  on conflict (user_id) do update set
    city = excluded.city, area = excluded.area, address = excluded.address;

  -- 3. Permanent address — "same as current" stores a copy of the current one.
  insert into public.permanent_addresses (user_id, city, area, address)
  values (
    v_uid,
    btrim(case when v_same then p_current_city    else p_permanent_city    end),
    btrim(case when v_same then p_current_area    else p_permanent_area    end),
    btrim(case when v_same then p_current_address else p_permanent_address end)
  )
  on conflict (user_id) do update set
    city = excluded.city, area = excluded.area, address = excluded.address;

  -- 4. Done: profiles_validate now finds both addresses.
  update public.profiles set profile_completed = true where id = v_uid;
end;
$$;

revoke execute on function public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text)
  from public, anon;
grant execute on function public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text)
  to authenticated;

-- CricEco · migration 34 · M9 fitness (self-logged workouts, the owner's
-- fitness view of the squad)
--
-- NOT APPLIED. Requires migrations 1–31 (independent of 32 / 33). Review
-- first; apply only with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261126_rollback_m9_fitness.sql.
-- Read-only check: supabase/tests/34_m9_fitness_postcheck.sql.
-- Local test: supabase/tests/local/29_m9_fitness_local_check.sql.
-- Design and app contract: docs/M9_FITNESS.md.
--
-- What changes (one transaction):
--   1. Table public.player_workouts: a player's self-logged workouts (the
--      app's Add Workout sheet, lib/core/models/fitness.dart WorkoutEntry):
--      date (today or earlier in Asia/Karachi, at most 365 days back, both
--      relative to created_at), type training | gym | running | nets | other,
--      minutes 1–600, intensity light | moderate | high, notes NULL or 1–120
--      characters (trimmed). Deleted with the profile (ON DELETE CASCADE),
--      so account deletion removes them. RLS on; the API roles may only
--      SELECT their own rows (no direct writes: through the RPCs below).
--   2. log_workout / my_workouts / delete_workout: the player's own rows.
--      At most 10 workouts on one date and 30 logged in any 24 hours.
--   3. The club owner's view of the squad's fitness inputs, for a date range
--      of at most 31 days: club_member_fitness (one summary row per active
--      member), club_member_workouts (their workouts, without notes) and
--      club_member_match_activity (their confirmed matches with their own
--      figures — what the client's Fitness Meter needs). Owner only, active
--      members only; a member whose profiles.show_stats is false is listed
--      with fitness_visible = false and no figures (and has no rows in the
--      other two). The owner's own row is always visible.
--   4. The internal helper fitness_member_matches (no access check, closed
--      to the API roles).
-- No existing object is changed; no row is changed or deleted.

do $$
begin
  if to_regclass('public.player_workouts') is not null
     or exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                   and p.proname in ('log_workout', 'my_workouts', 'delete_workout', 'club_member_fitness',
                                     'club_member_workouts', 'club_member_match_activity',
                                     'fitness_member_matches')) then
    raise exception 'migration 34: already applied (or a name is taken) — nothing changed';
  end if;
  if to_regclass('public.profiles') is null or to_regclass('public.clubs') is null
     or to_regclass('public.club_members') is null or to_regclass('public.matches') is null
     or to_regclass('public.match_results') is null or to_regclass('public.match_batting') is null
     or to_regclass('public.match_bowling') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'profiles' and column_name = 'show_stats'
                       and data_type = 'boolean' and is_nullable = 'NO')
     or to_regprocedure('public.set_profile_visibility(boolean, boolean)') is null
     or to_regprocedure('public.player_match_log(uuid, integer)') is null then
    raise exception 'migration 34: migrations 1–31 are required';
  end if;
end $$;

-- Errors (prefix "fitness:" · SQLSTATE): not authenticated / not allowed
-- (42501); invalid input (22023); workout / profile not found (P0002); a
-- limit reached (P0001).

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
create table public.player_workouts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null
               constraint player_workouts_user_id_fkey references public.profiles (id) on delete cascade,
  workout_date date not null,
  workout_type text not null
               constraint player_workouts_type_check
               check (workout_type in ('training', 'gym', 'running', 'nets', 'other')),
  minutes      integer not null
               constraint player_workouts_minutes_check check (minutes between 1 and 600),
  intensity    text not null
               constraint player_workouts_intensity_check check (intensity in ('light', 'moderate', 'high')),
  notes        text
               constraint player_workouts_notes_check
               check (notes is null or (notes = btrim(notes) and char_length(notes) between 1 and 120)),
  created_at   timestamptz not null default now(),
  -- Today or earlier in Pakistan, at most 365 days back — relative to when
  -- the row was logged (immutable, so a restore re-validates the same way).
  constraint player_workouts_date_window
    check (workout_date <= (created_at at time zone 'Asia/Karachi')::date
           and workout_date >= (created_at at time zone 'Asia/Karachi')::date - 365)
);

create index player_workouts_user_date_idx on public.player_workouts (user_id, workout_date);
create index player_workouts_user_created_idx on public.player_workouts (user_id, created_at);

comment on table public.player_workouts is
  'Migration 34 (M9): a player''s self-logged workouts (Add Workout). Written only by log_workout / delete_workout; read own rows directly or through my_workouts; club owners see active members'' rows (no notes) through club_member_workouts when show_stats allows.';

alter table public.player_workouts enable row level security;

create policy "player_workouts: select own"
  on public.player_workouts for select to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.player_workouts from public, anon, authenticated, service_role;
grant select on table public.player_workouts to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The player's own workouts
-- ---------------------------------------------------------------------------
-- Log a workout; returns the stored row. p_notes is trimmed, blank = NULL.
-- The caller's profile row is locked (FOR NO KEY UPDATE) so the limits are
-- counted one call at a time (and an account being deleted is waited for).
create function public.log_workout(
  p_workout_date date,
  p_workout_type text,
  p_minutes      integer,
  p_intensity    text,
  p_notes        text default null
)
returns table (
  id           uuid,
  workout_date date,
  workout_type text,
  minutes      integer,
  intensity    text,
  notes        text,
  created_at   timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if v_uid is null then
    raise exception 'fitness: not authenticated' using errcode = '42501';
  end if;
  if p_workout_date is null then
    raise exception 'fitness: invalid date' using errcode = '22023';
  end if;
  if p_workout_date > v_today then
    raise exception 'fitness: future date' using errcode = '22023';
  end if;
  if p_workout_date < v_today - 365 then
    raise exception 'fitness: date too old' using errcode = '22023';
  end if;
  if p_workout_type is null or p_workout_type not in ('training', 'gym', 'running', 'nets', 'other') then
    raise exception 'fitness: invalid type' using errcode = '22023';
  end if;
  if p_minutes is null or p_minutes not between 1 and 600 then
    raise exception 'fitness: invalid minutes' using errcode = '22023';
  end if;
  if p_intensity is null or p_intensity not in ('light', 'moderate', 'high') then
    raise exception 'fitness: invalid intensity' using errcode = '22023';
  end if;
  if char_length(v_notes) > 120 then
    raise exception 'fitness: notes too long' using errcode = '22023';
  end if;
  perform 1 from public.profiles p where p.id = v_uid for no key update;
  if not found then
    raise exception 'fitness: profile not found' using errcode = 'P0002';
  end if;
  if (select count(*) from public.player_workouts w
       where w.user_id = v_uid and w.workout_date = p_workout_date) >= 10 then
    raise exception 'fitness: too many workouts on that day' using errcode = 'P0001';
  end if;
  if (select count(*) from public.player_workouts w
       where w.user_id = v_uid and w.created_at > now() - interval '24 hours') >= 30 then
    raise exception 'fitness: too many workouts logged, try later' using errcode = 'P0001';
  end if;
  return query
    insert into public.player_workouts as w (user_id, workout_date, workout_type, minutes, intensity, notes)
    values (v_uid, p_workout_date, p_workout_type, p_minutes, p_intensity, v_notes)
    returning w.id, w.workout_date, w.workout_type, w.minutes, w.intensity, w.notes, w.created_at;
end;
$$;

-- The caller's workouts with p_from <= date <= p_to (both required, at most
-- 366 days), oldest first (the app's "newest last").
create function public.my_workouts(p_from date, p_to date)
returns table (
  id           uuid,
  workout_date date,
  workout_type text,
  minutes      integer,
  intensity    text,
  notes        text,
  created_at   timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'fitness: not authenticated' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 365 then
    raise exception 'fitness: invalid range' using errcode = '22023';
  end if;
  return query
    select w.id, w.workout_date, w.workout_type, w.minutes, w.intensity, w.notes, w.created_at
      from public.player_workouts w
     where w.user_id = (select auth.uid())
       and w.workout_date between p_from and p_to
     order by w.workout_date, w.created_at, w.id;
end;
$$;

-- Delete one of the caller's workouts. Someone else's workout and an unknown
-- id look the same (not found).
create function public.delete_workout(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'fitness: not authenticated' using errcode = '42501';
  end if;
  delete from public.player_workouts w where w.id = p_id and w.user_id = (select auth.uid());
  if not found then
    raise exception 'fitness: workout not found' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The owner's view of the squad
-- ---------------------------------------------------------------------------
-- A person's confirmed matches (every membership, any club) whose start falls
-- on p_from..p_to in Asia/Karachi, with their own figures (a Test's two
-- innings summed) — the same rules as player_match_log (migration 22).
-- Internal: no access check.
create function public.fitness_member_matches(p_user_id uuid, p_from date, p_to date)
returns table (
  match_id         uuid,
  starts_at        timestamptz,
  club_id          uuid,
  club_name        text,
  opponent_club_id uuid,
  opponent_name    text,
  result           text,
  bat_runs         integer,
  bat_balls        integer,
  bowl_balls       integer,
  bowl_runs        integer,
  bowl_wickets     integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with mine as (
    select m.id as member_id, m.club_id from public.club_members m where m.user_id = p_user_id
  ), apps as (
    select distinct r.match_id, r.version, mine.member_id, mine.club_id
      from public.match_results r
      join public.matches mt on mt.id = r.match_id
      join mine on mine.club_id in (mt.club_a_id, mt.club_b_id)
     where r.status = 'confirmed'
       and (mt.starts_at at time zone 'Asia/Karachi')::date between p_from and p_to
       and (r.player_of_match_member_id = mine.member_id
            or exists (select 1 from public.match_batting b
                        where b.match_id = r.match_id and b.version = r.version
                          and (b.member_id = mine.member_id or b.fielder_member_id = mine.member_id))
            or exists (select 1 from public.match_bowling w
                        where w.match_id = r.match_id and w.version = r.version and w.member_id = mine.member_id))
  )
  select a.match_id, mt.starts_at, a.club_id, c.name, o.id, o.name,
         case rr.outcome
           when 'tie' then 'tied'
           when 'no_result' then 'no_result'
           when 'abandoned' then 'abandoned'
           else case when (rr.outcome = 'club_a_won') = (mt.club_a_id = a.club_id) then 'won' else 'lost' end
         end,
         bt.runs, bt.balls, bw.balls, bw.runs, bw.wkts
    from apps a
    join public.matches mt on mt.id = a.match_id
    join public.match_results rr on rr.match_id = a.match_id and rr.version = a.version
    join public.clubs c on c.id = a.club_id
    join public.clubs o on o.id = case when mt.club_a_id = a.club_id then mt.club_b_id else mt.club_a_id end
   cross join lateral (
     select coalesce(sum(b.runs), 0)::int as runs, coalesce(sum(b.balls), 0)::int as balls
       from public.match_batting b
      where b.match_id = a.match_id and b.version = a.version and b.member_id = a.member_id) bt
   cross join lateral (
     select coalesce(sum(w.balls), 0)::int as balls, coalesce(sum(w.runs), 0)::int as runs,
            coalesce(sum(w.wickets), 0)::int as wkts
       from public.match_bowling w
      where w.match_id = a.match_id and w.version = a.version and w.member_id = a.member_id) bw
   order by mt.starts_at desc, a.match_id;
$$;

-- One row per ACTIVE member of the caller's club: the workouts logged on
-- p_from..p_to (at most 31 days) and the confirmed matches played then.
-- fitness_visible = false (figures NULL) for a member who hides their
-- statistics (profiles.show_stats = false); the owner's own row always shows.
-- training_load = Σ minutes / 60 × (light 0.5, moderate 1, high 1.5), as the
-- app's FitnessMeter.workoutLoad, rounded to 2 places.
create function public.club_member_fitness(p_club_id uuid, p_from date, p_to date)
returns table (
  member_id         uuid,
  user_id           uuid,
  member_role       text,
  fitness_visible   boolean,
  workout_sessions  integer,
  workout_minutes   integer,
  training_load     numeric,
  last_workout_date date,
  matches           integer,
  last_match_date   date
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'fitness: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = (select auth.uid())) then
    raise exception 'fitness: not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 30 then
    raise exception 'fitness: invalid range' using errcode = '22023';
  end if;
  return query
    with squad as (
      select m.id, m.user_id, m.member_role, m.joined_at,
             (p.show_stats or m.user_id = (select auth.uid())) as visible
        from public.club_members m
        join public.profiles p on p.id = m.user_id
       where m.club_id = p_club_id and m.status = 'active'
    )
    select s.id, s.user_id, s.member_role, s.visible,
           case when s.visible then wk.sessions end,
           case when s.visible then wk.total end,
           case when s.visible then wk.load end,
           case when s.visible then wk.last_day end,
           case when s.visible then mx.n end,
           case when s.visible then mx.last_day end
      from squad s
     cross join lateral (
       select count(*)::int as sessions, coalesce(sum(w.minutes), 0)::int as total,
              round(coalesce(sum(w.minutes / 60.0 * case w.intensity when 'light' then 0.5
                                                                    when 'moderate' then 1.0
                                                                    else 1.5 end), 0), 2) as load,
              max(w.workout_date) as last_day
         from public.player_workouts w
        where s.visible and w.user_id = s.user_id and w.workout_date between p_from and p_to) wk
     cross join lateral (
       select count(*)::int as n, max((f.starts_at at time zone 'Asia/Karachi')::date) as last_day
         from public.fitness_member_matches(s.user_id, p_from, p_to) f
        where s.visible) mx
     order by (s.member_role = 'owner') desc, s.joined_at, s.id;
end;
$$;

-- The workouts (no notes) of the caller's club's active, visible members on
-- p_from..p_to (at most 31 days). member_id is the membership in this club.
create function public.club_member_workouts(p_club_id uuid, p_from date, p_to date)
returns table (
  member_id    uuid,
  workout_id   uuid,
  workout_date date,
  workout_type text,
  minutes      integer,
  intensity    text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'fitness: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = (select auth.uid())) then
    raise exception 'fitness: not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 30 then
    raise exception 'fitness: invalid range' using errcode = '22023';
  end if;
  return query
    select m.id, w.id, w.workout_date, w.workout_type, w.minutes, w.intensity
      from public.club_members m
      join public.profiles p on p.id = m.user_id
      join public.player_workouts w on w.user_id = m.user_id
     where m.club_id = p_club_id and m.status = 'active'
       and (p.show_stats or m.user_id = (select auth.uid()))
       and w.workout_date between p_from and p_to
     order by m.id, w.workout_date, w.created_at, w.id;
end;
$$;

-- The confirmed matches (any of their clubs) of the caller's club's active,
-- visible members whose start falls on p_from..p_to in Asia/Karachi (at most
-- 31 days), with their own figures, newest first per member. member_id is
-- the membership in THIS club; club_id / club_name the club they played for.
create function public.club_member_match_activity(p_club_id uuid, p_from date, p_to date)
returns table (
  member_id        uuid,
  match_id         uuid,
  starts_at        timestamptz,
  club_id          uuid,
  club_name        text,
  opponent_club_id uuid,
  opponent_name    text,
  result           text,
  bat_runs         integer,
  bat_balls        integer,
  bowl_balls       integer,
  bowl_runs        integer,
  bowl_wickets     integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'fitness: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = (select auth.uid())) then
    raise exception 'fitness: not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 30 then
    raise exception 'fitness: invalid range' using errcode = '22023';
  end if;
  return query
    select m.id, f.match_id, f.starts_at, f.club_id, f.club_name, f.opponent_club_id, f.opponent_name, f.result,
           f.bat_runs, f.bat_balls, f.bowl_balls, f.bowl_runs, f.bowl_wickets
      from public.club_members m
      join public.profiles p on p.id = m.user_id
     cross join lateral public.fitness_member_matches(m.user_id, p_from, p_to) f
     where m.club_id = p_club_id and m.status = 'active'
       and (p.show_stats or m.user_id = (select auth.uid()))
     order by m.id, f.starts_at desc, f.match_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Privileges: signed-in users only; the helper for nobody
-- ---------------------------------------------------------------------------
revoke execute on function public.fitness_member_matches(uuid, date, date) from public, anon, authenticated;
revoke execute on function public.log_workout(date, text, integer, text, text) from public, anon;
revoke execute on function public.my_workouts(date, date) from public, anon;
revoke execute on function public.delete_workout(uuid) from public, anon;
revoke execute on function public.club_member_fitness(uuid, date, date) from public, anon;
revoke execute on function public.club_member_workouts(uuid, date, date) from public, anon;
revoke execute on function public.club_member_match_activity(uuid, date, date) from public, anon;

grant execute on function public.log_workout(date, text, integer, text, text) to authenticated;
grant execute on function public.my_workouts(date, date) to authenticated;
grant execute on function public.delete_workout(uuid) to authenticated;
grant execute on function public.club_member_fitness(uuid, date, date) to authenticated;
grant execute on function public.club_member_workouts(uuid, date, date) to authenticated;
grant execute on function public.club_member_match_activity(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Self-check (raises — rolling everything back — on any mismatch)
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn regprocedure;
begin
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.player_workouts'::regclass)
     or (select count(*) from pg_policy pol where pol.polrelid = 'public.player_workouts'::regclass) <> 1
     or not exists (select 1 from pg_policy pol
                     where pol.polrelid = 'public.player_workouts'::regclass
                       and pol.polname = 'player_workouts: select own' and pol.polcmd = 'r' and pol.polpermissive
                       and pol.polroles = array[(select oid from pg_roles where rolname = 'authenticated')]::oid[]) then
    raise exception 'migration 34 self-check: player_workouts RLS / policy';
  end if;
  if not has_table_privilege('authenticated', 'public.player_workouts', 'SELECT')
     or has_table_privilege('authenticated', 'public.player_workouts', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     or has_table_privilege('anon', 'public.player_workouts', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
    raise exception 'migration 34 self-check: player_workouts grants (authenticated SELECT only, anon nothing)';
  end if;
  if (select count(*) from pg_constraint k
       where k.conrelid = 'public.player_workouts'::regclass and k.convalidated
         and k.conname in ('player_workouts_type_check', 'player_workouts_minutes_check',
                           'player_workouts_intensity_check', 'player_workouts_notes_check',
                           'player_workouts_date_window')) <> 5
     or not exists (select 1 from pg_constraint k
                     where k.conrelid = 'public.player_workouts'::regclass and k.conname = 'player_workouts_user_id_fkey'
                       and k.contype = 'f' and k.confrelid = 'public.profiles'::regclass and k.confdeltype = 'c') then
    raise exception 'migration 34 self-check: player_workouts constraints / cascade';
  end if;
  foreach v_fn in array array['public.log_workout(date, text, integer, text, text)', 'public.my_workouts(date, date)',
                              'public.delete_workout(uuid)', 'public.club_member_fitness(uuid, date, date)',
                              'public.club_member_workouts(uuid, date, date)',
                              'public.club_member_match_activity(uuid, date, date)']::regprocedure[] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
       or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
      raise exception 'migration 34 self-check: % privileges / properties', v_fn;
    end if;
  end loop;
  if has_function_privilege('authenticated', 'public.fitness_member_matches(uuid, date, date)', 'execute')
     or has_function_privilege('anon', 'public.fitness_member_matches(uuid, date, date)', 'execute')
     or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p
          where p.oid = 'public.fitness_member_matches(uuid, date, date)'::regprocedure) then
    raise exception 'migration 34 self-check: fitness_member_matches must be closed to the API roles';
  end if;
end $$;

notify pgrst, 'reload schema';

-- CricEco · migration 3/4 · player_profiles
-- ERD v8 PlayerProfile: 0..1 per user, written when Player setup completes
-- on Role Selection.
--
-- Values are the app's enums as snake_case codes (labels stay in the app):
--   player_role    batsman | bowler | all_rounder
--                  (the app has no "Wicketkeeper" role: wicket keeping is the
--                   is_wicketkeeper flag, offered to Batsmen only)
--   batting_style  right_handed | left_handed
--   bowling_style  right_arm_fast | right_arm_medium | right_arm_off_spin |
--                  right_arm_leg_spin | left_arm_fast | left_arm_medium |
--                  left_arm_orthodox | left_arm_chinaman
-- Role rules (same as the app's Role Selection):
--   Batsman     → batting style; no bowling style; may keep wicket
--   Bowler      → bowling style; no batting style
--   All-Rounder → batting and bowling style
--
-- NOT APPLIED. Requires migration 1 (public.profiles, set_last_updated_at).

create table public.player_profiles (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null unique default auth.uid()
                    references public.profiles (id) on delete cascade,
  player_role     text not null,
  batting_style   text,
  bowling_style   text,
  is_wicketkeeper boolean not null default false,
  created_at      timestamptz not null default now(),
  last_updated_at timestamptz not null default now(),

  constraint player_profiles_player_role_check
    check (player_role in ('batsman', 'bowler', 'all_rounder')),
  constraint player_profiles_batting_style_check
    check (batting_style is null or batting_style in ('right_handed', 'left_handed')),
  constraint player_profiles_bowling_style_check
    check (bowling_style is null or bowling_style in (
      'right_arm_fast', 'right_arm_medium', 'right_arm_off_spin', 'right_arm_leg_spin',
      'left_arm_fast', 'left_arm_medium', 'left_arm_orthodox', 'left_arm_chinaman')),
  -- Batting style exactly when the role bats (everyone except Bowlers).
  constraint player_profiles_batting_follows_role
    check ((player_role = 'bowler') = (batting_style is null)),
  -- Bowling style exactly when the role bowls (everyone except Batsmen).
  constraint player_profiles_bowling_follows_role
    check ((player_role = 'batsman') = (bowling_style is null)),
  constraint player_profiles_wicketkeeper_batsman_only
    check (not is_wicketkeeper or player_role = 'batsman')
);

comment on table public.player_profiles is 'ERD v8 PlayerProfile: cricket details, 0..1 per user.';

create trigger player_profiles_set_last_updated_at
  before update on public.player_profiles
  for each row execute function public.set_last_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security: own row only. No DELETE policy.
-- (Clubs seeing players — Player Hunt — is a later, separate read policy or
-- view that exposes only public fields; not part of this stage.)
-- ---------------------------------------------------------------------------
alter table public.player_profiles enable row level security;

create policy "player_profiles: select own"
  on public.player_profiles for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "player_profiles: insert own"
  on public.player_profiles for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy "player_profiles: update own"
  on public.player_profiles for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke all on table public.player_profiles from anon, authenticated;
grant select, insert, update on table public.player_profiles to authenticated;

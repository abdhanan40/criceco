-- CricEco · migration 27 · push delivery (M3 P5)
--
-- NOT APPLIED. Requires migrations 25–26 (the server inbox, preferences).
-- Rollback: supabase/rollback/20261122_rollback_push_delivery.sql.
-- Read-only check: supabase/tests/27_push_delivery_postcheck.sql.
-- Local tests: supabase/tests/local/22_push_delivery_local_check.sql (+ 22b_push_delivery_concurrency.sh).
-- Dispatcher: supabase/functions/push-dispatch (Edge Function, FCM HTTP v1).
-- Design: docs/NOTIFICATIONS_BACKEND.md ("P5").
--
-- Approved 2026-11-22 (M3 P5):
--   * the app registers its device's FCM token; one person may have several
--     devices (at most 10 — the oldest goes); a token belongs to one person
--     (signing in on a shared phone moves it);
--   * every new notification for someone with a device is queued in
--     push_deliveries; muted categories are never created (migration 26), so
--     they are never pushed;
--   * the queue wakes the push-dispatch Edge Function by a webhook, once per
--     transaction, through pg_net — with its URL and a shared secret from
--     Supabase Vault ('push_dispatch_url', 'push_dispatch_secret'). Without
--     pg_net / those secrets (local, or before that separate, approved
--     settings step) nothing is sent: deliveries wait in the queue;
--   * waking the dispatcher can never make the user's action fail (unlike
--     writing the notification itself, P1-A): a failed wake leaves the
--     delivery pending for the next wake (and the sweeper, P6);
--   * the dispatcher claims deliveries and reports results through two
--     service_role-only functions; nobody reads the tables directly;
--   * push text is written by the dispatcher from the type and parameters —
--     no token, text or personal data is ever stored in the queue.

do $$
begin
  if to_regclass('public.notifications') is null or to_regclass('public.notification_preferences') is null then
    raise exception 'migration 27: migrations 25–26 are required';
  end if;
  if to_regclass('public.device_tokens') is not null or to_regclass('public.push_deliveries') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('notifications_queue_push', 'push_wake', 'register_push_device',
                                     'unregister_push_device', 'push_claim', 'push_report')) then
    raise exception 'migration 27: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
-- One row per app installation that may receive push (Android only for now).
create table public.device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null
               constraint device_tokens_user_id_fkey references public.profiles (id) on delete cascade,
  token        text not null
               constraint device_tokens_token_check check (char_length(token) between 20 and 4096 and token !~ '\s')
               constraint device_tokens_token_key unique,
  platform     text not null
               constraint device_tokens_platform_check check (platform in ('android')),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index device_tokens_user_seen_idx on public.device_tokens (user_id, last_seen_at desc);

comment on table public.device_tokens is
  'FCM registration tokens (M3 P5). Written only by register_ / unregister_push_device and push_report.';

-- The push queue: one row per notification to push. No text, no token.
create table public.push_deliveries (
  notification_id uuid primary key
                  constraint push_deliveries_notification_id_fkey references public.notifications (id) on delete cascade,
  status          text not null default 'pending'
                  constraint push_deliveries_status_check check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts        smallint not null default 0
                  constraint push_deliveries_attempts_check check (attempts between 0 and 10),
  created_at      timestamptz not null default now(),
  claimed_at      timestamptz,
  finished_at     timestamptz,
  -- An FCM error code (e.g. 'UNAVAILABLE'), never content.
  last_error      text
                  constraint push_deliveries_last_error_check check (last_error is null or last_error ~ '^[A-Za-z0-9_.:-]{1,60}$'),
  constraint push_deliveries_finished_consistency
    check ((status in ('sent', 'failed', 'skipped')) = (finished_at is not null))
);

create index push_deliveries_open_idx on public.push_deliveries (created_at) where status in ('pending', 'sending');

comment on table public.push_deliveries is
  'Push queue (M3 P5). Written only by the queue trigger and push_claim / push_report.';

-- ---------------------------------------------------------------------------
-- 2. Waking the dispatcher (once per transaction; never fails the action)
-- ---------------------------------------------------------------------------
create or replace function public.push_wake()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tx     text := txid_current()::text;
  v_url    text;
  v_secret text;
begin
  if coalesce(current_setting('criceco.push_woken', true), '') = v_tx then
    return;
  end if;
  perform set_config('criceco.push_woken', v_tx, true);
  -- pg_net and Vault are enabled on the project in a separate, approved
  -- settings step. Until then (and locally) the queue just waits.
  if to_regnamespace('net') is null or to_regnamespace('vault') is null then
    return;
  end if;
  begin
    execute 'select max(decrypted_secret) filter (where name = ''push_dispatch_url''),
                    max(decrypted_secret) filter (where name = ''push_dispatch_secret'')
               from vault.decrypted_secrets
              where name in (''push_dispatch_url'', ''push_dispatch_secret'')'
       into v_url, v_secret;
    if v_url is null or v_secret is null then
      return;
    end if;
    -- pg_net sends after the commit (and not at all on a rollback).
    execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 5000)'
      using v_url, '{}'::jsonb,
            jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret);
  exception when others then
    -- Never fail the user's action over a wake-up: the delivery stays
    -- pending for the next wake (and the sweeper, P6).
    raise warning 'push_wake: dispatcher not woken (%)', sqlstate;
  end;
end;
$$;

-- A new notification for someone with a device → the queue (+ a wake).
create or replace function public.notifications_queue_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.device_tokens t where t.user_id = new.recipient_id) then
    insert into public.push_deliveries (notification_id) values (new.id) on conflict do nothing;
    perform public.push_wake();
  end if;
  return null;
end;
$$;

create trigger notifications_queue_push
  after insert on public.notifications
  for each row execute function public.notifications_queue_push();

-- ---------------------------------------------------------------------------
-- 3. The app: register / unregister this device (signed in)
-- ---------------------------------------------------------------------------
create or replace function public.register_push_device(p_token text, p_platform text default 'android')
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_token text := btrim(coalesce(p_token, ''));
begin
  if v_uid is null then
    raise exception 'push: not authenticated' using errcode = '42501';
  end if;
  if char_length(v_token) not between 20 and 4096 or v_token ~ '\s' then
    raise exception 'push: invalid token' using errcode = '22023';
  end if;
  if p_platform is null or p_platform not in ('android') then
    raise exception 'push: invalid platform' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid) then
    raise exception 'push: not found' using errcode = 'P0002';
  end if;
  -- A token is one installation: signing in there as someone else moves it.
  insert into public.device_tokens as t (user_id, token, platform)
  values (v_uid, v_token, p_platform)
  on conflict (token) do update
     set user_id = excluded.user_id, platform = excluded.platform, last_seen_at = now(),
         created_at = case when t.user_id = excluded.user_id then t.created_at else now() end;
  -- At most 10 devices per person: the longest unseen go.
  delete from public.device_tokens t
   where t.user_id = v_uid
     and t.id not in (select x.id from public.device_tokens x where x.user_id = v_uid
                       order by x.last_seen_at desc, x.id desc limit 10);
end;
$$;

-- Returns how many were removed (0 when the token isn't this person's).
create or replace function public.unregister_push_device(p_token text)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'push: not authenticated' using errcode = '42501';
  end if;
  delete from public.device_tokens t where t.token = btrim(coalesce(p_token, '')) and t.user_id = v_uid;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The dispatcher (service_role only: the push-dispatch Edge Function)
-- ---------------------------------------------------------------------------
-- Claims up to [p_limit] deliveries (pending, or stuck "sending" for 5
-- minutes), oldest first, skipping rows another dispatcher holds. Older than
-- a day: not pushed any more (skipped). Recipients without a device any more:
-- skipped. Returns what to send: the notification's type and parameters and
-- the recipient's tokens.
create or replace function public.push_claim(p_limit integer default 100)
returns table (
  notification_id uuid,
  inbox           text,
  type            text,
  params          jsonb,
  club_id         uuid,
  match_id        uuid,
  subject_id      uuid,
  created_at      timestamptz,
  attempts        smallint,
  tokens          text[]
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  -- Too old to be useful on a lock screen.
  update public.push_deliveries d
     set status = 'skipped', finished_at = now(), last_error = 'EXPIRED'
   where d.status in ('pending', 'sending') and d.created_at <= now() - interval '1 day';

  return query
    with claimable as (
      select d.notification_id
        from public.push_deliveries d
       where (d.status = 'pending' or (d.status = 'sending' and d.claimed_at < now() - interval '5 minutes'))
       order by d.created_at, d.notification_id
       limit v_limit
         for update skip locked
    ),
    claimed as (
      update public.push_deliveries d
         set status = 'sending', attempts = least(d.attempts + 1, 10), claimed_at = now()
        from claimable c
       where d.notification_id = c.notification_id
      returning d.notification_id, d.attempts
    )
    select n.id, n.inbox, n.type, n.params, n.club_id, n.match_id, n.subject_id, n.created_at, c.attempts,
           coalesce((select array_agg(t.token order by t.last_seen_at desc)
                       from public.device_tokens t where t.user_id = n.recipient_id), '{}')
      from claimed c
      join public.notifications n on n.id = c.notification_id
     order by n.created_at, n.id;

  -- Claimed but nobody's device any more: nothing to send.
  update public.push_deliveries d
     set status = 'skipped', finished_at = now(), last_error = 'NO_DEVICE'
    from public.notifications n
   where d.notification_id = n.id and d.status = 'sending' and d.claimed_at = now()
     and not exists (select 1 from public.device_tokens t where t.user_id = n.recipient_id);
end;
$$;

-- Records what the dispatcher did. p_results: a JSON array (at most 500) of
--   {"notification_id": uuid, "outcome": "sent" | "retry" | "failed",
--    "error": "<FCM code>" (optional), "invalid_tokens": ["…"] (optional)}
-- A retry goes back to pending (until 3 attempts, then failed). Invalid
-- tokens are removed — only the recipient's own. Returns how many were
-- recorded; deliveries that aren't "sending" are ignored.
create or replace function public.push_report(p_results jsonb)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_item    jsonb;
  v_id      uuid;
  v_outcome text;
  v_error   text;
  v_done    integer := 0;
  v_rows    integer;
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 500 then
    raise exception 'push: invalid' using errcode = '22023';
  end if;
  for v_item in select e from jsonb_array_elements(p_results) e loop
    if jsonb_typeof(v_item) <> 'object'
       or coalesce(v_item ->> 'notification_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_item ->> 'outcome', '') not in ('sent', 'retry', 'failed') then
      raise exception 'push: invalid' using errcode = '22023';
    end if;
    v_id := (v_item ->> 'notification_id')::uuid;
    v_outcome := v_item ->> 'outcome';
    v_error := nullif(left(regexp_replace(coalesce(v_item ->> 'error', ''), '[^A-Za-z0-9_.:-]', '', 'g'), 60), '');

    update public.push_deliveries d
       set status = case
                      when v_outcome = 'sent' then 'sent'
                      when v_outcome = 'retry' and d.attempts < 3 then 'pending'
                      else 'failed'
                    end,
           finished_at = case when v_outcome = 'retry' and d.attempts < 3 then null else now() end,
           last_error = case when v_outcome = 'sent' then null else v_error end
     where d.notification_id = v_id and d.status = 'sending';
    get diagnostics v_rows = row_count;
    v_done := v_done + v_rows;

    if jsonb_typeof(v_item -> 'invalid_tokens') = 'array' then
      delete from public.device_tokens t
       using public.notifications n
       where n.id = v_id and t.user_id = n.recipient_id
         and t.token in (select jsonb_array_elements_text(v_item -> 'invalid_tokens'));
    end if;
  end loop;
  return v_done;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Privileges
-- ---------------------------------------------------------------------------
revoke all on table public.device_tokens, public.push_deliveries from public, anon, authenticated, service_role;
alter table public.device_tokens enable row level security;
alter table public.push_deliveries enable row level security;

revoke execute on function public.push_wake() from public, anon, authenticated, service_role;
revoke execute on function public.notifications_queue_push() from public, anon, authenticated, service_role;

revoke execute on function public.register_push_device(text, text) from public, anon, service_role;
revoke execute on function public.unregister_push_device(text) from public, anon, service_role;
grant execute on function public.register_push_device(text, text) to authenticated;
grant execute on function public.unregister_push_device(text) to authenticated;

revoke execute on function public.push_claim(integer) from public, anon, authenticated;
revoke execute on function public.push_report(jsonb) from public, anon, authenticated;
grant execute on function public.push_claim(integer) to service_role;
grant execute on function public.push_report(jsonb) to service_role;

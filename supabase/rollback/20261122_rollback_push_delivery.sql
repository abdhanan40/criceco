-- CricEco · ROLLBACK of migration 27 (push delivery, M3 P5).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Undeploy (or stop) the push-dispatch Edge Function first.
--
-- Removes push: registered devices and the push queue are deleted. It
-- REFUSES while any exists, unless you confirm in the same transaction:
--   set local criceco.rollback_push_discarded = 'yes';
-- Nothing else changes: notifications, preferences, announcements and every
-- other table stay; only the queue trigger on notifications is removed.
-- An app built with push then fails to register its device (it says so and
-- carries on) — ship a build without the Firebase settings first.

do $$
begin
  if to_regclass('public.device_tokens') is null then
    raise exception 'rollback 27: migration 27 is not applied — nothing changed';
  end if;
  if (exists (select 1 from public.device_tokens) or exists (select 1 from public.push_deliveries))
     and coalesce(current_setting('criceco.rollback_push_discarded', true), '') <> 'yes' then
    raise exception 'rollback 27: devices or queued pushes exist — set criceco.rollback_push_discarded = ''yes'' to discard them (nothing changed)';
  end if;
end $$;

drop trigger if exists notifications_queue_push on public.notifications;

drop function if exists public.register_push_device(text, text);
drop function if exists public.unregister_push_device(text);
drop function if exists public.push_claim(integer);
drop function if exists public.push_report(jsonb);
drop function if exists public.notifications_queue_push();
drop function if exists public.push_wake();

drop table if exists public.push_deliveries;
drop table if exists public.device_tokens;

notify pgrst, 'reload schema';

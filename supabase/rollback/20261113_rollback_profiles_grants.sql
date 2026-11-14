-- CricEco · ROLLBACK of migration 20261113090000_harden_profiles_grants.sql (Stage 4.3.7).
--
-- Restores Supabase's default grants on public.profiles: every privilege
-- for anon and authenticated — the state before migration 10.
--
-- WARNING: this RE-OPENS what migration 10 closed — TRUNCATE (not covered by
-- row level security), DELETE, REFERENCES, TRIGGER and (PostgreSQL 17)
-- MAINTAIN for authenticated, and every privilege for anon. Use it only if
-- migration 10 breaks something, and apply migration 10 again once fixed.
-- The exact grants before migration 10 are the output of
-- tests/00h_preflight_profiles_grants.sql kept from before it was applied;
-- compare after running this (any grantor / grant-option detail beyond
-- Supabase's defaults must be restored by hand from that record).
--
-- Changes nothing else: no row, column, constraint, policy, trigger,
-- function or other role's grant (service_role / postgres untouched).
-- Independent of migrations 6–9: may be run with them applied or not.

begin;

grant all on table public.profiles to anon, authenticated;

notify pgrst, 'reload schema';

commit;

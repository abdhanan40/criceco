-- CricEco · ROLLBACK of migration 20261111090000_create_update_profile_details.sql (Stage 4.3.6a).
--
-- Removes only what that migration added: update_profile_details(). No
-- table, row, column, policy, grant or other function is touched, so no data
-- is lost. Roll back any app build that calls update_profile_details FIRST
-- (the older build saves Edit Profile with separate table updates).
-- Migrations 1–8 (save_profile_setup v1 / v2, city_id, its triggers) stay.
--
-- ORDER: run this FIRST — before the rollbacks of migration 8
-- (rollback/20261110_rollback_address_city_id.sql), migration 6
-- (rollback/20261110_rollback_locations.sql) and migrations 1–4
-- (rollback/20261027_rollback_profile_schema.sql). update_profile_details()
-- uses their tables and columns, but a plpgsql body records no dependency on
-- them: rolling any of them back first would succeed and leave this function
-- in place, failing at run time (e.g. column "city_id" does not exist) on
-- every Edit Profile save.

begin;

drop function if exists public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text);

notify pgrst, 'reload schema';

commit;

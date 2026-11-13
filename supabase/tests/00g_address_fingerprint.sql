-- CricEco · address rows FINGERPRINT (read-only). Run immediately BEFORE
-- migration 8 and again immediately AFTER it: the two results must be
-- identical. It covers what the backfill must never change — city text,
-- area, address, created_at and last_updated_at of every row of both address
-- tables (city_id, which migration 8 adds, is deliberately left out). Output
-- is a count and an md5 hash only: no ids, no addresses.
-- (Writes by users between the two runs also change it — run both back to
-- back, as with 00c_profiles_fingerprint.sql.)

select count(*) as address_rows,
       md5(coalesce(string_agg(row_text, '|' order by row_text), '')) as fingerprint
  from (
    select 'c' || user_id::text || '|' || city || '|' || area || '|' || address || '|'
           || created_at::text || '|' || last_updated_at::text as row_text
      from public.current_addresses
    union all
    select 'p' || user_id::text || '|' || city || '|' || area || '|' || address || '|'
           || created_at::text || '|' || last_updated_at::text
      from public.permanent_addresses
  ) r;

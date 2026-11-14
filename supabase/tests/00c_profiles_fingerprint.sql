-- CricEco · fingerprint of the EXISTING profiles rows (READ-ONLY).
-- Run BEFORE the migrations and again AFTER them: both results must be
-- identical. It covers the six original columns of every row, so any change
-- to an existing value (or a lost / added row) changes the fingerprint.
-- Prints only a count and a hash — no personal data.
--
-- Query 1: all rows — compare right after migrating, before any new sign-up.
-- Query 2: only rows created before CUTOFF — still comparable after test
--          users sign up. Set CUTOFF to the time you ran query 1 the first
--          time (created_at can't change after migration 1).

select count(*) as rows,
       md5(string_agg(md5(row(id, created_at, full_name, phone, role, profile_completed)::text), ''
                      order by id)) as fingerprint
from public.profiles;

select count(*) as rows_before_cutoff,
       md5(string_agg(md5(row(id, created_at, full_name, phone, role, profile_completed)::text), ''
                      order by id)) as fingerprint_before_cutoff
from public.profiles
where created_at < timestamptz 'CUTOFF';

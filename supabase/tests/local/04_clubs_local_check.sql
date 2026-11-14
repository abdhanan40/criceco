-- CricEco · LOCAL TEST ONLY — clubs at scale: join-code uniqueness and
-- format over many clubs, role precedence for every owner, ON DELETE CASCADE,
-- and the pre-existing (legacy) profiles left untouched.
-- Creates and deletes auth users, so it refuses to run on a real Supabase
-- project (whose auth.users has an encrypted_password column). Rolled back.
-- Run after migration 5 on the local test database (as the database owner).

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
end $$;

begin;

-- Legacy rows before (everything that isn't created below).
create temporary table legacy_before on commit drop as
  select id, role, full_name, phone, profile_completed from public.profiles;

-- 300 owners with a completed Profile Setup; a third start as Players.
insert into auth.users (email)
select 'club-owner-' || g || '@local.test' from generate_series(1, 300) g;

create temporary table owners on commit drop as
  select u.id, row_number() over (order by u.email) as n
  from auth.users u where u.email like 'club-owner-%@local.test';

insert into public.current_addresses (user_id, city, area, address)
select id, 'Lahore', 'Gulberg', 'Street ' || n from owners;
insert into public.permanent_addresses (user_id, city, area, address)
select id, 'Lahore', 'Gulberg', 'Street ' || n from owners;
update public.profiles p
   set full_name = 'Owner ' || o.n, phone = '+923001234567', date_of_birth = date '1990-01-01',
       profile_completed = true,
       role = case when o.n % 3 = 0 then 'player' end
  from owners o where p.id = o.id;

insert into public.clubs (owner_id, name, city, club_type)
select id, 'Club ' || n, 'Lahore', 'corporate' from owners;

do $$
begin
  if (select count(*) from public.clubs c join owners o on o.id = c.owner_id) <> 300 then
    raise exception 'FAIL: expected 300 clubs';
  end if;
  if (select count(distinct c.code) from public.clubs c join owners o on o.id = c.owner_id) <> 300 then
    raise exception 'FAIL: join codes are not unique';
  end if;
  if exists (select 1 from public.clubs c join owners o on o.id = c.owner_id
             where c.code !~ '^[A-HJ-NP-Z2-9]{6}$') then
    raise exception 'FAIL: a join code is outside the 6-character code alphabet';
  end if;
  if exists (select 1 from public.profiles p join owners o on o.id = p.id
             where p.role is distinct from 'club_owner') then
    raise exception 'FAIL: an owner (NULL or player before) is not club_owner';
  end if;
  raise notice 'PASS: 300 clubs, 300 unique codes from the code alphabet, every owner club_owner';
end $$;

-- ON DELETE CASCADE: deleting the auth user removes profile and club.
do $$
declare
  victim uuid := (select id from owners where n = 1);
begin
  delete from auth.users where id = victim;
  if exists (select 1 from public.profiles where id = victim)
     or exists (select 1 from public.clubs where owner_id = victim) then
    raise exception 'FAIL: the club survived its owner';
  end if;
  raise notice 'PASS: a club goes with its owner (ON DELETE CASCADE)';
end $$;

-- Legacy profiles (the 5 pre-existing rows in the fixture) are untouched and
-- own no club; legacy club_owner rows simply have none yet.
do $$
begin
  if exists (
       select 1 from legacy_before b
       join public.profiles p on p.id = b.id
       where (p.role, p.full_name, p.phone, p.profile_completed)
             is distinct from (b.role, b.full_name, b.phone, b.profile_completed)) then
    raise exception 'FAIL: migration 5 changed a pre-existing profile';
  end if;
  if exists (select 1 from public.clubs c join legacy_before b on b.id = c.owner_id) then
    raise exception 'FAIL: a pre-existing profile got a club';
  end if;
  raise notice 'PASS: profiles that existed before this check are unchanged (% rows), none owns a club',
    (select count(*) from legacy_before);
end $$;

select 'ALL LOCAL CLUBS CHECKS PASSED' as result;

rollback;

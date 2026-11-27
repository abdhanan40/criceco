#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 31 (M5 media uploads / M6 privacy
# visibility): the Supabase Storage stand-in, then (optionally) the check.
#
# The Supabase Postgres image creates the "storage" schema but NOT its
# tables: those come from the Storage API service, which a throwaway
# database container doesn't run. Migration 31 needs storage.buckets,
# storage.objects and storage.foldername(text), so this installs a minimal
# copy of them, matching the hosted Storage schema in what migration 31 and
# local check 26 use:
#   * storage.buckets  (id, name, owner, owner_id, public, avif_autodetection,
#     file_size_limit, allowed_mime_types, created_at, updated_at), RLS on;
#   * storage.objects  (id, bucket_id → buckets, name, owner, owner_id,
#     metadata, user_metadata, path_tokens (generated), version, timestamps),
#     unique (bucket_id, name), RLS on;
#   * storage.foldername(text) with the Storage API's body;
#   * owner supabase_storage_admin when that role exists (as hosted), ALL
#     granted to anon / authenticated / service_role (the Storage API's
#     grants) and to postgres WITH GRANT OPTION (the image's migration
#     20250623125453). On the Supabase image the "postgres" role then creates
#     the storage.objects policies through supautils.policy_grants, as on a
#     hosted project.
# NOT copied: the Storage API's own triggers and functions (prefixes, search,
# delete protection, updated_at), which migration 31 doesn't touch.
#
# Usage:
#   PSQL_ADMIN='docker exec -i criceco-m5-test psql -U supabase_admin -d postgres' \
#     bash supabase/tests/local/26_m5_m6_media_local_check.sh stub
#   PSQL='docker exec -i criceco-m5-test psql -U postgres -d postgres' \
#     bash supabase/tests/local/26_m5_m6_media_local_check.sh check
# $PSQL_ADMIN must be a superuser of the LOCAL test database (supabase_admin
# on the Supabase image, postgres on plain PostgreSQL). "stub" refuses when
# storage.objects already exists or any auth user has a password or a
# non-test e-mail. "check" runs 26_m5_m6_media_local_check.sql (one
# transaction, rolled back).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-}"

case "$mode" in
stub)
  : "${PSQL_ADMIN:?set PSQL_ADMIN to a superuser psql command for the LOCAL test database}"
  $PSQL_ADMIN -X -q -v ON_ERROR_STOP=1 <<'SQL'
begin;
do $$
declare
  v_pw boolean := false;
begin
  if to_regclass('storage.objects') is not null or to_regclass('storage.buckets') is not null then
    raise exception 'LOCAL ONLY: storage tables already exist — not a fresh local test database';
  end if;
  if to_regclass('auth.users') is not null then
    if exists (select 1 from information_schema.columns
                where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
      execute 'select exists (select 1 from auth.users where coalesce(encrypted_password, '''') <> '''')' into v_pw;
    end if;
    if v_pw or exists (select 1 from auth.users where email is null or email not like '%@local.test') then
      raise exception 'LOCAL ONLY: this database has real users — refusing';
    end if;
  end if;
end $$;

create schema if not exists storage;

create table storage.buckets (
  id                 text primary key,
  name               text not null,
  owner              uuid,
  owner_id           text,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now(),
  public             boolean default false,
  avif_autodetection boolean default false,
  file_size_limit    bigint,
  allowed_mime_types text[]
);
create unique index bname on storage.buckets using btree (name);

create table storage.objects (
  id               uuid primary key default gen_random_uuid(),
  bucket_id        text constraint "objects_bucketId_fkey" references storage.buckets (id),
  name             text,
  owner            uuid,
  owner_id         text,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata         jsonb,
  path_tokens      text[] generated always as (string_to_array(name, '/')) stored,
  version          text,
  user_metadata    jsonb
);
create unique index bucketid_objname on storage.objects using btree (bucket_id, name);
create index name_prefix_search on storage.objects (name text_pattern_ops);

alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;

-- The Storage API's definition.
create or replace function storage.foldername(name text)
returns text[]
language plpgsql
as $f$
declare
  _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end
$f$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_storage_admin') then
    alter table storage.buckets owner to supabase_storage_admin;
    alter table storage.objects owner to supabase_storage_admin;
    alter function storage.foldername(text) owner to supabase_storage_admin;
  end if;
end $$;
grant usage on schema storage to anon, authenticated, service_role;
grant all on storage.buckets, storage.objects to anon, authenticated, service_role;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'postgres' and not rolsuper) then
    grant usage on schema storage to postgres with grant option;
    grant all on storage.buckets, storage.objects to postgres with grant option;
  end if;
end $$;
commit;
\echo 'storage stand-in installed (LOCAL ONLY)'
SQL
  ;;
check)
  : "${PSQL:?set PSQL to a psql command for the LOCAL test database (database owner)}"
  $PSQL -X -q -v ON_ERROR_STOP=1 < "$HERE/26_m5_m6_media_local_check.sql"
  ;;
*)
  echo "usage: $0 stub|check   (see the header)" >&2
  exit 2
  ;;
esac

# Location seed (Stage 4.2, D1)

Data for the location tables of migration 6
(`supabase/migrations/20261110090000_create_locations.sql`): provinces,
districts, cities, city ↔ district links and city aliases.

- **Source:** GeoNames only (CC BY 4.0, see `/ATTRIBUTION.md` and `SOURCES.md`).
  HDX is restricted until its upstream licence is verified; PBS is not used.
- **Status:**
  - the data review is approved (2026-11-10) and `overrides.csv` reflects it;
  - tested locally on PostgreSQL 17.11: loaded twice (no changes the second time, stable ids) and checked with `tests/07_locations_data_check.sql`;
  - **not loaded on the live project.** That is a separate, approved production step.

## Files

| File | Kind | What |
|---|---|---|
| `province_display.csv` | curated | One row per GeoNames province record: canonical name, display name, kind, order |
| `featured_cities.csv` | curated | The app's 20 featured cities (`kPakistanCities` order), each pinned to one GeoNames id |
| `overrides.csv` | curated | Reviewed corrections on top of GeoNames: exclude, inactive, rename, qualifier, district link. Every row has a reason; `PROPOSED` rows await review |
| `provinces.csv`, `districts.csv`, `cities.csv`, `city_districts.csv`, `city_aliases.csv` | generated | The seed rows, keyed by GeoNames ids |
| `apply_locations.sql` | generated | The data script: one transaction, re-runnable |
| `import_report.md` | generated | Counts, featured cities, applied overrides, cities without a district, name clashes, ambiguous aliases |

Never edit the generated files by hand. Change the curated files, then regenerate.

## Regenerating

The GeoNames files are the reviewed downloads (checksums in `SOURCES.md`), extracted:

```bash
dart run tool/locations/build_locations.dart \
  --dump "<review folder>/extracted/geonames_dump/PK.txt" \
  --alternatenames "<review folder>/extracted/geonames_alternatenames/PK.txt" \
  --source-version "<text from SOURCES.md>"
```

`--check` writes nothing and exits 1 if any generated file would change (determinism / staleness).
The build stops, writing nothing, on any rule violation, for example:
- an unknown override id;
- a featured city that isn't importable;
- two cities of one province with the same name and no qualifier.

## Rules (`tool/locations/locations_import.dart`)

- **Provinces:** the 7 GeoNames province (ADM1) records, with names and kinds from `province_display.csv`.
- **Districts:** GeoNames ADM2 records (historical ADM2H records are never taken).
  - The name is GeoNames' ASCII name without the " District" suffix.
  - Other spellings go to `alt_names`.
  - `overrides.csv` may exclude, rename or deactivate a district.
- **Cities:** GeoNames populated places.
  - **Always taken:** capital and admin seats (PPLC, PPLA, PPLA2, PPLA3).
  - **Also taken:** other places with a GeoNames population of 10,000 or more.
  - **Forced in:** the featured cities.
  - **Never taken:** PPLX, PPLQ, PPLW, PPLH.
  - **District link:** the GeoNames district, when it was imported and is active; otherwise none. A city may have no district (Karachi and Islamabad have none in GeoNames).
  - Two cities with one name in a province need a qualifier, or one excluded.
- **Aliases:** alternate names of the imported cities.
  - **Kept:** untagged, English and Urdu names. Urdu is stored, not displayed yet.
  - **Dropped:** codes and links, other languages, and spellings equal to the city name.
  - An alias equal to another city's name in the same province is stored as not searchable.
- **Search key:** `searchKey()` is an exact mirror of `public.location_search_key()`. Both were checked equal on every generated string.

## Deferred for verification (data review, 2026-11-10)

Kept exactly as GeoNames has them until verified against official sources. Nothing about current administrative boundaries is assumed.

- **Former FATA / PATA units:** frontier regions and tribal areas, and the "Agency" / "Protected Area" district names.
- **Missing district:** Keamari (Karachi).
- **District names:** "District of West Karachi"; "Rahimyar Khan" against the city "Rahim Yar Khan"; "Hunza-Nagar" listed alongside "Nagar".
- **Possible duplicate record:** Athmuqam (7536245) and Athhmuqam (10944629) in Azad Jammu and Kashmir.
- **Wrong aliases:** "Bahawalpur" as an alias of Bahawalnagar, and "Shāhdādpur" of Shahdad Kot. Both are stored as not searchable.

## Loading on the live project (only after separate approval)

Apply migration 6 first. Then run `apply_locations.sql` **whole** in the SQL Editor:
- it matches rows on GeoNames ids, never on database ids;
- it updates changed rows;
- it never deletes or deactivates anything;
- it reports rows the new version no longer has.

Then run `tests/07_locations_data_check.sql`. Its expected counts match `import_report.md`, so update them whenever the seed is regenerated. To undo: `rollback/20261110_rollback_locations_data.sql`, which only works while nothing else references the location tables.

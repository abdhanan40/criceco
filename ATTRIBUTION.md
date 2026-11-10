# Third-party data attribution

## GeoNames: location names and identifiers

CricEco's province, district, city and city-alias data
(`supabase/seed/locations/`) is derived from **GeoNames**
(https://www.geonames.org). It is licensed under the
**Creative Commons Attribution 4.0 International** licence
(https://creativecommons.org/licenses/by/4.0/).

**Changes made by CricEco:**
- **Selected a subset of populated places:** administrative seats, places with a GeoNames population of 10,000 or more, and the app's 20 featured cities.
- **Used GeoNames' ASCII spellings, and dropped the " District" suffix from district names.** The original spellings are kept as alternate names.
- **Excluded records:**
  - one duplicate district record;
  - four city records: two with a population copied from another place, one duplicate, and one suspicious record pending verification.
- **Added a qualifier** (the district name) to tell apart two different towns with the same name.
- **Linked cities to districts only from GeoNames' own codes.** A city is linked only when its GeoNames district was imported; no link was added or changed by hand.
- **Filtered alternate names:** kept English, Urdu and untagged names only, and marked aliases that equal another city's name as not searchable.

No district was renamed and no administrative boundary was changed or assumed.
The rules are in `supabase/seed/locations/README.md`. Each individual
correction is listed with its reason in `supabase/seed/locations/overrides.csv`
and `import_report.md`.

The data is provided "as is", without warranty or any representation of
accuracy, timeliness or completeness. GeoNames does not endorse CricEco.

In-app text for the Licences screen (Stage 4.3):

> Place names and identifiers from GeoNames (https://www.geonames.org), licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Modified by CricEco. Provided "as is", without warranty.

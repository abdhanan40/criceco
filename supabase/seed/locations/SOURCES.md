# Location data sources (Stage 4.2)

| Source | File | Downloaded (UTC) | Bytes | SHA-256 |
|---|---|---|---|---|
| GeoNames gazetteer, Pakistan | https://download.geonames.org/export/dump/PK.zip | 2026-11-10 13:31:38 | 6,239,101 | `457286ef5292a09703fa70d602ed835ea81ed39a74837f7ec862b3433d8d03e4` |
| GeoNames alternate names, Pakistan | https://download.geonames.org/export/dump/alternatenames/PK.zip | 2026-11-10 13:31:56 | 1,979,342 | `91f29cf289e3a61f21a71913bbcbcd4ec5454942fc37ceadefd61b132be359e5` |

- **Licence:** both GeoNames files are Creative Commons Attribution 4.0 (https://creativecommons.org/licenses/by/4.0/). This is stated in the readme inside each archive and in the GeoNames export terms (commercial use allowed). The data is provided "as is".
- **Where the files are:** they live outside the repository, in the licence-review folder with its `REPORT.md`, `SHA256SUMS.txt` and download log. Raw dumps are never committed.
- **Not used:**
  - HDX COD-AB (CONDITIONAL: World Food Programme upstream terms unverified; restricted to internal review);
  - PBS (excluded).

`--source-version` text used for the current seed:
`GeoNames PK.zip (sha256 457286ef…8d03e4) + alternatenames/PK.zip (sha256 91f29cf2…be359e5), downloaded 2026-11-10 13:31 UTC`

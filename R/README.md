# AERMET Station Selection Audit

`station_selection_audit.R` builds an auditable station-selection table for
an ISH vs GHCNh AERMET terrain study: one simple-terrain and one
complex-terrain surface station per state (lower 48 + DC), each tagged by
terrain mechanism and paired to the nearest active NWS upper-air (RAOB)
station.

## Before you run it

1. Open `station_selection_audit.R` and set `crosswalk_path` to your
   2,061-station CONUS crosswalk file.
2. Check the `crosswalk_cols` and `mshr_cols` mappings near the top against
   your crosswalk's actual column names and the Enhanced MSHR file's actual
   header row. A wrong guess here is not silent: the script stops on load
   with the real column names printed out, so treat that error message as
   the fix instructions.
3. Install the required packages if you have not already:
   `install.packages(c("tidyverse","sf","terra","units","elevatr","rnaturalearth","geosphere","leaflet","htmlwidgets","glue","httr","lubridate"))`
   `sf`/`terra` need GDAL, GEOS, and PROJ installed at the system level;
   see their respective package documentation if `install.packages()` fails
   to compile.

## Running it

```r
source("R/station_selection_audit.R")
```

First run downloads and caches the Enhanced MSHR file, the IGRA v2 station
list, Natural Earth coastline/lakes/rivers, and a CONUS elevation raster
under `data/raw/` (git-ignored -- see `.gitignore`). Later runs reuse the
cache. Every download is retried with exponential backoff and the script
stops with a clear message rather than proceeding on a partial or missing
source.

## Outputs

- `data/processed/station_audit_table.csv` -- the selection table
- `data/processed/README.md` -- provenance: source URLs, retrieval dates,
  thresholds used, the column-name mapping in effect, coverage gaps,
  known limitations, and `sessionInfo()` for the run that produced it
- `data/processed/unmatched_crosswalk_stations.csv` -- crosswalk rows that
  could not be matched to Enhanced MSHR on any key (only written if
  non-empty)
- `outputs/station_map.html` -- a leaflet QA map of the picks, colored by
  terrain class

## Testing done on this copy of the script

This repo's execution environment has no CRAN access and no network route
to `ncei.noaa.gov` or Natural Earth's download host (`naciscdn.org`), but
`sf`, `terra`, `geosphere`, `elevatr`, `rnaturalearth`, `leaflet`, and
`htmlwidgets` were all installed anyway (apt for the ones packaged for
Ubuntu, `R CMD INSTALL` from CRAN's read-only GitHub mirrors for the
rest), and AWS's terrain-tile host that `elevatr` uses turned out to be
reachable. That made it possible to run the real script **unmodified**
through all 7 steps against the synthetic fixtures in
`data/raw/test_fixtures/`, with only the two `rnaturalearth::ne_download()`
call bodies (still blocked) swapped for small synthetic sf objects --
Step 3's DEM fetch, every CRS transform, buffer, distance, and relief
calculation, and the leaflet map are all the real, unmodified code
running against real data. That run caught and fixed three real bugs: a
PROJ-network-grid failure mode that silently corrupted geometry, a
`glue()` indentation bug in the README template, and an S2-spherical-
geometry bug that was silently clipping real coastline out of the crop
step across the Gulf Coast and Florida (not sandbox-specific -- this one
would have hit a real run too). Full account, including what still
isn't exercised, in `data/raw/test_fixtures/TEST_HARNESS_NOTES.md`.

Run it once on your data and report back any errors -- given the above,
they are more likely to be a stale download URL or a column-name mismatch
than a logic problem.

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

## A note on this copy of the script

It was written and reviewed in an environment with no R installation and
no network access to `ncei.noaa.gov`, so it could not be executed end to
end before being committed. The logic has been checked by hand, and the
crosswalk/MSHR column-name mappings are called out explicitly as
assumptions (see the comments at the top of the script) precisely because
they could not be verified against real files. Run it once on your data
and report back any errors -- they are expected to be a handful of column
names or a stale download URL, not a logic problem.

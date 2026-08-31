# =====================================================================
# station_selection_audit.R
#
# Purpose
#   Build an auditable station-selection table for an ISH vs GHCNh
#   AERMET study. For each of the lower 48 states plus DC, select:
#     - one simple-terrain surface station
#     - one complex-terrain surface station
#   drawn from an existing CONUS station crosswalk, each tagged by
#   terrain class (coastal / mountain / river / simple) and paired to
#   the nearest active NWS upper-air (RAOB) station.
#
# Auditability
#   Every row in the output CSV traces to a named, dated source file
#   cached under data/raw. Nothing here is invented: if a required
#   input cannot be reached or parsed, the script stops with a clear
#   message instead of filling in a guess or proceeding on partial
#   data.
#
# Outputs
#   data/processed/station_audit_table.csv   the selection table
#   data/processed/README.md                 provenance and limitations
#   outputs/station_map.html                 optional leaflet QA map
#
# Usage
#   Edit the PARAMETERS block below (especially crosswalk_path and the
#   crosswalk_cols / mshr_cols name mappings), then:
#     source("R/station_selection_audit.R")
#
# Known limitation of this copy of the script: it was written and
# reviewed without a live R session and without network access to
# NCEI (both were unavailable in the environment it was authored in).
# The logic has been checked by hand but not executed end to end.
# Run it once on a small test and report any errors back so they can
# be fixed against real data.
# =====================================================================

# ---------------------------------------------------------------------
# PACKAGES
# ---------------------------------------------------------------------
required_pkgs <- c(
  "tidyverse", "sf", "terra", "units", "elevatr", "rnaturalearth",
  "geosphere", "leaflet", "htmlwidgets", "glue", "httr", "lubridate"
)
missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  stop(
    "Missing required packages: ", paste(missing_pkgs, collapse = ", "), "\n",
    "Install with: install.packages(c(", paste0('"', missing_pkgs, '"', collapse = ", "), "))",
    call. = FALSE
  )
}
suppressPackageStartupMessages({
  library(tidyverse)
  library(sf)
  library(terra)
  library(units)
  library(elevatr)
  library(rnaturalearth)
  library(geosphere)
  library(leaflet)
  library(htmlwidgets)
  library(glue)
})

# PROJ (used by sf's st_transform()) can reach for higher-accuracy datum
# grids over the network (cdn.proj.org) when it thinks one might be
# available. Loading both sf and terra in the same session can leave that
# network path enabled; if the grid CDN is then unreachable (firewalled,
# offline, this kind of sandboxed environment), the failed fetch does not
# just fall back gracefully -- it was observed here to silently corrupt
# the transformed geometry (st_is_valid() -> NA, followed by a GEOS crash
# in st_distance()/st_union() with no warning that would point at the
# real cause). Forcing PROJ to use its local grids avoids that failure
# mode entirely; the accuracy cost is at most a few meters, negligible
# against the 5-10 km terrain thresholds this script uses.
sf::sf_proj_network(FALSE)

# sf's default S2 (spherical) geometry engine treats the "straight" edges
# of a lon/lat bounding box as geodesic arcs, not flat lines. For a wide,
# low-latitude box like conus_bbox, that bulges the bottom edge several
# degrees north in the middle -- confirmed here to silently clip real
# coastline south of about 26.5N out of the Step 3a/3b st_crop() calls,
# well north of the true ymin and squarely through the Gulf Coast and
# Florida. Every geometry in this script is planar by the time it matters
# (everything gets st_transform()'d to EPSG:5070 before any distance,
# buffer, or union), so there is no correctness cost to using planar
# (GEOS) semantics throughout instead, and it makes st_crop() behave like
# the flat rectangle its bbox argument implies.
sf::sf_use_s2(FALSE)

# Some federal download endpoints (HOMR's included -- observed here
# returning a 200 OK with a ~150-line, 1-column page instead of the real
# file) serve an interstitial/error page instead of the requested file
# for a request that does not look like it came from a browser. Setting
# a standard browser user-agent for every download.file() call in this
# script is a cheap, harmless way to reduce the odds of that.
options(HTTPUserAgent = paste(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
  "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
))

# ---------------------------------------------------------------------
# PARAMETERS -- edit these, nothing else below should need to change
# ---------------------------------------------------------------------

# --- Your crosswalk -----------------------------------------------------
# Path to your existing 2,061-station CONUS crosswalk. CSV is assumed;
# change the read_csv() call in Step 1 if yours is a different format.
crosswalk_path <- "data/raw/station_crosswalk.csv"

# Column-name mapping for the crosswalk, confirmed against the real file.
# None of these are hard-required: a crosswalk legitimately may not carry
# every identifier type (this one has no WMO column at all, for example)
# or any of the enrichment fields below -- a name that does not match a
# real column just warns and that field/tier degrades gracefully (see
# check_cols()). The one thing Step 1 does insist on is that AFTER
# standardization at least one identifier column produced a usable,
# non-missing key somewhere in the file; with none at all, no join to
# MSHR is possible and the script stops rather than silently producing
# an all-unmatched table.
#
# lat/lon/begin_date/end_date/platform are read from the crosswalk itself
# (this one already carries them) and preferred over Enhanced MSHR's
# versions where present; MSHR only fills in what the crosswalk lacks
# (elevation, UTC offset, state, WMO). ish_filename/ghcnh_filename/
# ghcn_id/match_method/notes are carried straight through to the output
# for traceability -- exactly the ISH-vs-GHCNh linkage this study needs --
# and match_method/notes also feed crosswalk_match_issue_flag (Step 3),
# so a row your own crosswalk already flagged for manual review does not
# quietly win the "clean" simple-terrain pick over an unflagged one.
crosswalk_cols <- list(
  wmo            = "WMO",                        # not present in this crosswalk; the WMO join tier just never fires
  icao           = "ICAO",
  faa            = "FAA Identifier",
  usaf           = "USAF ID",
  wban           = "WBAN ID",
  state          = "STATE",                      # not present; filled in from MSHR
  station_name   = "Station Name",
  lat            = "Latitude",
  lon            = "Longitude",
  begin_date     = "Data Period Starting",        # YYYYMMDD
  end_date       = "Data Period Ending",          # YYYYMMDD, a real date here (not an MSHR-style "still active" sentinel)
  platform       = "Station Type (ASOS/AWOS)",    # currently all "UNKNOWN" in this file -- treated as missing, falls back to MSHR
  ish_filename   = "ISH Filename",
  ghcnh_filename = "GHCNh Filename",
  ghcn_id        = "GHCN_ID",
  match_method   = "match_method",                # this crosswalk's own match-quality label, e.g. "UNMATCHED"
  notes          = "notes"                        # this crosswalk's own QA notes, e.g. a flagged coordinate mismatch
)

# --- Enhanced MSHR column mapping ---------------------------------------
# ASSUMPTION: field names below follow NCEI's typical Enhanced MSHR
# schema as documented historically on the HOMR reports page. NCEI has
# changed these names before. The script reads the file's actual header
# row (Step 2) and validates against it, stopping with the real column
# names if a REQUIRED field is missing. It also downloads the layout
# file for your own manual confirmation, since a delimited file's
# header row is the authoritative column list, but the layout file is
# still the documentation of record for provenance.
mshr_cols <- list(
  icao       = "ICAO_ID",          # required (used in tier-1 join)
  faa        = "FAA_ID",           # required (used in tier-1 join)
  wban       = "WBAN_ID",          # required (used in tier-2 join)
  wmo        = "WMO_ID",           # required (used in tier-3 join)
  lat        = "LAT_DEC",          # required
  lon        = "LON_DEC",          # required
  elev_m     = "ELEV_GROUND",      # optional, assumed meters -- verify against layout file
  utc_offset = "UTC_OFFSET",       # optional
  state      = "STATE_PROV",       # optional
  station_name = "NAME_PRINCIPAL", # optional
  begin_date = "BEGIN_DATE",       # optional, assumed YYYYMMDD
  end_date   = "END_DATE",         # optional, assumed YYYYMMDD, "99991231" or similar = still active
  platform   = "PLATFORM"          # optional -- ASOS/AWOS designation; may not exist in Enhanced MSHR.
                                    # If it is missing entirely, the ASOS-over-AWOS tie-break in Step 5
                                    # simply has no effect and falls through to the next tie-break.
)

# --- Terrain thresholds --------------------------------------------------
coastal_km             <- 10   # primary coastal-proximity threshold
coastal_km_sensitivity <- 20   # secondary distance recorded for sensitivity, not used in complex_flag
mountain_relief_m      <- 300  # relief within mountain_radius_km that counts as "mountain"
mountain_radius_km     <- 10
river_km               <- 5    # max distance to a major river to test the river mechanism
river_relief_m         <- 50   # relief within river_radius_km required (proximity alone is not enough)
river_radius_km        <- 5
simple_relief_max_m    <- 100  # rolling-hill guard: relief within mountain_radius_km must be at or
                                # below this for a station to qualify as "simple" even if it clears
                                # the mountain/coastal/river tests. Tunable.
river_scalerank_max    <- 3    # Natural Earth rivers_lake_centerlines scalerank cutoff (1 = most
                                # major, e.g. the Mississippi; 10 = minor). Lower keeps only major channels.

# --- RAOB pairing ---------------------------------------------------------
raob_active_since  <- 2024  # IGRA lstyear >= this counts as "active"
raob_elev_diff_m   <- 500   # elevation-difference proxy threshold for barrier_review_flag.
                             # This is a simple proxy, not a real terrain-barrier analysis -- a
                             # large surface-to-RAOB elevation gap just means the pairing deserves
                             # a human look, not that it is necessarily wrong.
dist_outlier_pctile <- 0.90 # national percentile of surface-to-RAOB distance above which
                             # dist_outlier_flag is set

# --- DEM ------------------------------------------------------------------
dem_z <- 7  # elevatr/AWS Terrain Tiles zoom level. Coarse: at z7 the native resolution is roughly
            # 300-600 m depending on latitude, well larger than many narrow mountain valleys or
            # river gorges. This UNDERSTATES relief in narrow-valley terrain -- a station that is
            # genuinely complex on the ground can still test as "simple" here. Raise dem_z for a
            # sharper (slower, larger) DEM if this matters for your final picks; always sanity-check
            # borderline stations against a topographic map before treating a "simple" tag as final.

# --- Cache / output locations ---------------------------------------------
data_raw_dir       <- "data/raw"
data_processed_dir <- "data/processed"
output_dir         <- "outputs"
for (d in c(data_raw_dir, data_processed_dir, output_dir)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

# --- Source URLs ------------------------------------------------------------
# mshr_file_url confirmed via web search (this environment still cannot
# reach ncei.noaa.gov directly to verify by fetching it): the correct
# current filename is MSHR_Enhanced_Table.txt (an earlier version of this
# script had the wrong case/name and 404'd). HOMR's file links carry a
# `;jsessionid=...` suffix when captured from a live browser session, but
# the bare URL below (no jsessionid) should still resolve -- that suffix
# is session-affinity bookkeeping, not part of the resource path. If this
# 404s again, open mshr_reports_page in a browser, find the current
# "Enhanced" download link, and update mshr_file_url to match exactly.
#
# No layout/format file has a confirmed stable URL (search turned up
# nothing, and every HOMR file link appears to be a session-generated
# download rather than a fixed path) -- the layout-file download step
# below is skipped, and a delimited file's own header row (read at parse
# time) is the authoritative column list anyway.
mshr_reports_page <- "https://www.ncei.noaa.gov/access/homr/reports"
mshr_file_url      <- "https://www.ncei.noaa.gov/access/homr/file/MSHR_Enhanced_Table.txt"
igra_list_url       <- "https://www.ncei.noaa.gov/data/integrated-global-radiosonde-archive/doc/igra2-station-list.txt"

# --- Download retry behavior -----------------------------------------------
download_max_retries <- 4
download_base_wait_s <- 2  # doubles each retry: 2, 4, 8, 16s

# --- Lower 48 + DC ------------------------------------------------------
conus_states <- c(setdiff(datasets::state.abb, c("AK", "HI")), "DC")

# Bounding box (lon/lat, with a small margin) used both to crop the
# world-scale Natural Earth layers before the heavy geometry operations
# in Step 3, and to fetch the DEM. Purely a performance/extent setting;
# it does not change which stations are near which features as long as
# it comfortably contains the lower 48 + DC, which it does.
conus_bbox <- c(xmin = -126, xmax = -65, ymin = 24, ymax = 50)


# =======================================================================
# HELPER FUNCTIONS
# =======================================================================

# Registry of every downloaded/cached source file, for the README.
download_log <- new.env()

log_download <- function(name, url, path, source_last_modified = NA_character_) {
  download_log[[name]] <- list(
    url = url,
    path = path,
    retrieved_at = as.character(Sys.time()),
    file_mtime = as.character(file.info(path)$mtime),
    source_last_modified = source_last_modified
  )
}

# Best-effort fetch of a URL's Last-Modified header, for provenance.
# Returns NA rather than failing the run if the server does not send one.
get_last_modified <- function(url) {
  tryCatch({
    resp <- httr::HEAD(url, httr::timeout(15))
    lm <- httr::headers(resp)[["last-modified"]]
    if (is.null(lm)) NA_character_ else lm
  }, error = function(e) NA_character_)
}

# Download a URL to a cached local file, retrying with exponential
# backoff. Skips the download entirely if the destination already
# exists AND passes `validate` (that is the cache). Stops with a clear
# message if every retry fails -- callers should not proceed on a
# missing/partial/wrong file.
#
# `validate`, if given, is a function(path) -> logical checking that the
# downloaded content actually looks like what it is supposed to be, not
# just that *a* file landed. This matters because some servers (HOMR's
# file endpoint, observed here) return an HTTP 200 with an unrelated
# interstitial or error page instead of the real file for a request that
# doesn't look like it came from a browser -- no HTTP error at all, just
# wrong content, so a plain "did the download succeed" check misses it
# entirely. A pre-existing cached file is re-validated too and
# re-downloaded if it fails, so a bad file from an earlier run does not
# get trusted just because it exists at the expected path.
cache_download <- function(url, dest, max_retries = download_max_retries,
                           base_wait = download_base_wait_s, validate = NULL) {
  content_ok <- function(path) {
    file.exists(path) && file.info(path)$size > 0 && (is.null(validate) || isTRUE(validate(path)))
  }
  if (file.exists(dest) && file.info(dest)$size > 0) {
    if (content_ok(dest)) {
      message("Using cached file: ", dest)
      return(invisible(dest))
    }
    message("Cached file at ", dest, " failed its content check (likely a stale bad ",
            "download from an earlier run); re-downloading.")
    file.remove(dest)
  }
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  attempt <- 0
  repeat {
    attempt <- attempt + 1
    ok <- tryCatch({
      utils::download.file(url, dest, mode = "wb", quiet = TRUE)
      content_ok(dest)
    }, error = function(e) FALSE)
    if (isTRUE(ok)) break
    if (attempt >= max_retries) {
      validation_note <- ""
      if (!is.null(validate) && file.exists(dest) && file.info(dest)$size > 0) {
        preview <- tryCatch(
          paste(utils::head(readLines(dest, n = 3, warn = FALSE), 3), collapse = " | "),
          error = function(e) "(could not read the file to preview it)"
        )
        validation_note <- paste0(
          "\nThe last response downloaded without an HTTP error but did not pass its ",
          "content check (first line(s): ", preview, "). The server is likely returning ",
          "an interstitial, login, or error page instead of the real file for a plain ",
          "request, rather than a broken link -- try downloading it manually in a browser ",
          "and placing it at ", dest, " (this script will use it as-is if it passes the ",
          "same check)."
        )
      }
      stop(
        "Could not download a required source file after ", max_retries, " attempts:\n  ",
        url, "\nCheck the URL is still current and that you have network access.",
        validation_note, "\nNot proceeding on a missing/invalid input.", call. = FALSE
      )
    }
    wait <- base_wait * 2^(attempt - 1)
    message("Download failed or did not validate (attempt ", attempt, "/", max_retries, "). ",
            "Retrying in ", wait, "s: ", url)
    Sys.sleep(wait)
  }
  invisible(dest)
}

# Content-check for the Enhanced MSHR file: real data is pipe-delimited
# with several dozen fields per row. A header line with fewer than 5
# pipes (an HTML interstitial/error page would have zero) is almost
# certainly the wrong content, not real MSHR data -- this deliberately
# does not also require a large row count, so it still passes a small,
# legitimately filtered extract (including this repo's own test
# fixtures).
validate_mshr_content <- function(path) {
  lines <- tryCatch(readLines(path, n = 2, warn = FALSE), error = function(e) character(0))
  if (length(lines) < 2) return(FALSE)
  lengths(regmatches(lines[1], gregexpr("\\|", lines[1]))) >= 5
}

# Content-check for the IGRA v2 station list: real rows are fixed-width
# and at least 81 characters (lstyear ends at column 81).
validate_igra_content <- function(path) {
  lines <- tryCatch(readLines(path, n = 1, warn = FALSE), error = function(e) character(0))
  length(lines) >= 1 && nchar(lines[1]) >= 81
}

# Standardize an identifier column: trim, uppercase, treat common
# missing-value tokens as NA, and optionally zero-pad to a fixed width
# (WMO ids are 5 digits, USAF 6, WBAN 5, and different source files pad
# these inconsistently).
std_id <- function(x, width = NULL) {
  x <- stringr::str_trim(toupper(as.character(x)))
  x[x %in% c("", "NA", "NULL", "9999", "99999", "999999")] <- NA
  if (!is.null(width)) {
    x <- ifelse(is.na(x), NA_character_, stringr::str_pad(x, width, pad = "0"))
  }
  x
}

# Check a data frame against a role -> column-name mapping. Stops with
# the real column names on a missing REQUIRED field (so a wrong guess
# in the mapping is diagnosable in one error message); warns and leaves
# the field unusable (NA downstream) for a missing OPTIONAL field.
check_cols <- function(df, col_map, required_roles, df_name) {
  for (role in names(col_map)) {
    nm <- col_map[[role]]
    if (!nm %in% names(df)) {
      if (role %in% required_roles) {
        stop(
          "Expected column '", nm, "' (role: '", role, "') was not found in ", df_name, ".\n",
          "Actual columns present in the file:\n  ", paste(names(df), collapse = ", "), "\n",
          "Fix the '", role, "' entry in the column-name mapping near the top of this script ",
          "to match one of the columns above, then re-run.",
          call. = FALSE
        )
      } else {
        warning(
          "Optional column '", nm, "' (role: '", role, "') not found in ", df_name,
          "; continuing with NA for this field. Downstream logic that depends on it ",
          "(e.g. an ASOS/AWOS tie-break, or state grouping) degrades gracefully.",
          call. = FALSE
        )
      }
    }
  }
  invisible(TRUE)
}

# Pull a column by mapped name, returning an all-NA character vector if
# that column does not exist in the data frame (paired with check_cols()
# above, which already warned about it).
safe_col <- function(df, name) {
  if (!is.null(name) && name %in% names(df)) df[[name]] else rep(NA_character_, nrow(df))
}

# Great-circle distance in km between two lon/lat point sets (WGS84
# ellipsoidal distance via geosphere, vectorized row-wise).
gc_dist_km <- function(lon1, lat1, lon2, lat2) {
  geosphere::distGeo(cbind(lon1, lat1), cbind(lon2, lat2)) / 1000
}

# Relief (max - min elevation) within `radius_km` of each point in
# `points_sf`, read from a projected-CRS terra SpatRaster `dem`.
# points_sf must already be in the same projected CRS as dem.
relief_in_radius <- function(dem, points_sf, radius_km) {
  buf <- sf::st_buffer(points_sf, dist = units::set_units(radius_km, "km"))
  buf_v <- terra::vect(buf)
  vals <- terra::extract(dem, buf_v, fun = function(x) {
    x <- x[!is.na(x)]
    if (length(x) == 0) return(NA_real_)
    max(x) - min(x)
  })
  # terra::extract() returns an ID column plus one value column per layer
  vals[[2]]
}


# =======================================================================
# STEP 1: Read crosswalk, standardize identifier keys
# =======================================================================
if (!file.exists(crosswalk_path)) {
  stop(
    "Crosswalk file not found at: ", crosswalk_path, "\n",
    "Set crosswalk_path at the top of this script to the location of your ",
    "CONUS station crosswalk before running.", call. = FALSE
  )
}

crosswalk_raw <- readr::read_csv(crosswalk_path, col_types = readr::cols(.default = "c"))
message("Loaded crosswalk: ", nrow(crosswalk_raw), " rows from ", crosswalk_path,
        " (expected 2,061).")

# Nothing here is individually required (see the comment on crosswalk_cols
# above) -- a missing name just warns and that column reads as all-NA.
check_cols(crosswalk_raw, crosswalk_cols, required_roles = character(0), df_name = "the crosswalk")

crosswalk <- crosswalk_raw %>%
  mutate(
    station_uid  = dplyr::row_number(),  # stable id used for anti_join tracking below
    wmo_std      = std_id(safe_col(crosswalk_raw, crosswalk_cols$wmo), width = 5),
    icao_std     = std_id(safe_col(crosswalk_raw, crosswalk_cols$icao)),
    faa_std      = std_id(safe_col(crosswalk_raw, crosswalk_cols$faa)),
    usaf_std     = std_id(safe_col(crosswalk_raw, crosswalk_cols$usaf), width = 6),
    wban_std     = std_id(safe_col(crosswalk_raw, crosswalk_cols$wban), width = 5),
    state_cw     = safe_col(crosswalk_raw, crosswalk_cols$state),
    name_cw      = safe_col(crosswalk_raw, crosswalk_cols$station_name),
    lat_cw       = suppressWarnings(as.numeric(safe_col(crosswalk_raw, crosswalk_cols$lat))),
    lon_cw       = suppressWarnings(as.numeric(safe_col(crosswalk_raw, crosswalk_cols$lon))),
    begin_date_cw_raw = safe_col(crosswalk_raw, crosswalk_cols$begin_date),
    end_date_cw_raw   = safe_col(crosswalk_raw, crosswalk_cols$end_date),
    platform_cw  = dplyr::na_if(safe_col(crosswalk_raw, crosswalk_cols$platform), "UNKNOWN"),
    ish_filename   = safe_col(crosswalk_raw, crosswalk_cols$ish_filename),
    ghcnh_filename = safe_col(crosswalk_raw, crosswalk_cols$ghcnh_filename),
    ghcn_id        = safe_col(crosswalk_raw, crosswalk_cols$ghcn_id),
    match_method_cw = safe_col(crosswalk_raw, crosswalk_cols$match_method),
    notes_cw        = safe_col(crosswalk_raw, crosswalk_cols$notes)
  ) %>%
  # ICAO and FAA are treated as one join tier: use whichever is present
  # for a given row, preferring ICAO.
  mutate(icao_faa_std = dplyr::coalesce(icao_std, faa_std))

# At least one identifier column must have produced a usable key for at
# least one row, or no join to MSHR is possible at all. Stop with a clear
# message rather than silently producing an all-unmatched table.
if (!any(!is.na(crosswalk$icao_faa_std) | !is.na(crosswalk$wban_std) |
         !is.na(crosswalk$usaf_std) | !is.na(crosswalk$wmo_std))) {
  stop(
    "None of the identifier columns (icao/faa/usaf/wban/wmo) in crosswalk_cols ",
    "produced a single usable, non-missing key after standardization. Check ",
    "the crosswalk_cols mapping against the real column names printed above.",
    call. = FALSE
  )
}


# =======================================================================
# STEP 2: Read Enhanced MSHR, join to crosswalk, attach lat/lon/elev/UTC/POR
# =======================================================================

# --- 2a. Download MSHR data file (cached) --------------------------------
# No layout/format file is fetched here -- it has no confirmed stable URL
# (see the comment on mshr_file_url above). If a required-column check
# below fails, confirm field definitions by hand from mshr_reports_page.
mshr_raw_path <- file.path(data_raw_dir, "MSHR_Enhanced_Table.txt")

tryCatch({
  cache_download(mshr_file_url, mshr_raw_path, validate = validate_mshr_content)
  log_download("MSHR_Enhanced_Table.txt", mshr_file_url, mshr_raw_path,
               get_last_modified(mshr_file_url))
}, error = function(e) stop(conditionMessage(e), call. = FALSE))

# --- 2b. Parse MSHR -------------------------------------------------------
# The data file's own header row is the authoritative column list for a
# delimited export (more reliable than hardcoding positions from a doc
# that can drift, and there is no confirmed layout file to cross-check
# against anyway).
mshr_raw <- readr::read_delim(
  mshr_raw_path, delim = "|",
  col_types = readr::cols(.default = "c"),
  trim_ws = TRUE
)
message("Loaded Enhanced MSHR: ", nrow(mshr_raw), " rows, ", ncol(mshr_raw), " columns.")

check_cols(
  mshr_raw, mshr_cols,
  required_roles = c("icao", "faa", "wban", "wmo", "lat", "lon"),
  df_name = "the Enhanced MSHR file"
)

mshr <- mshr_raw %>%
  mutate(
    icao_std      = std_id(safe_col(mshr_raw, mshr_cols$icao)),
    faa_std       = std_id(safe_col(mshr_raw, mshr_cols$faa)),
    icao_faa_std  = dplyr::coalesce(icao_std, faa_std),
    wban_std      = std_id(safe_col(mshr_raw, mshr_cols$wban), width = 5),
    wmo_std       = std_id(safe_col(mshr_raw, mshr_cols$wmo), width = 5),
    lat           = suppressWarnings(as.numeric(safe_col(mshr_raw, mshr_cols$lat))),
    lon           = suppressWarnings(as.numeric(safe_col(mshr_raw, mshr_cols$lon))),
    elev_m        = suppressWarnings(as.numeric(safe_col(mshr_raw, mshr_cols$elev_m))),
    utc_offset    = safe_col(mshr_raw, mshr_cols$utc_offset),
    state_mshr    = safe_col(mshr_raw, mshr_cols$state),
    name_mshr     = safe_col(mshr_raw, mshr_cols$station_name),
    begin_date_raw = safe_col(mshr_raw, mshr_cols$begin_date),
    end_date_raw   = safe_col(mshr_raw, mshr_cols$end_date),
    platform       = safe_col(mshr_raw, mshr_cols$platform)
  ) %>%
  filter(!is.na(lat), !is.na(lon)) %>%
  # keep one row per identifier combo (MSHR can carry historical
  # multi-row station records); take the most recently reported row
  distinct(icao_faa_std, wban_std, wmo_std, .keep_all = TRUE)

# --- 2c. Cascading join: ICAO/FAA, then WBAN, then WMO --------------------
# Each tier only attempts to match crosswalk rows not already matched by
# a stronger key, and every matched row is tagged with which key worked
# (match_key_used) so the audit trail shows how each station was tied
# to its MSHR record.
join_tier <- function(cw, mshr_df, cw_key, mshr_key, tier_name) {
  cw %>%
    filter(!is.na(.data[[cw_key]])) %>%
    inner_join(
      mshr_df %>% filter(!is.na(.data[[mshr_key]])),
      by = setNames(mshr_key, cw_key)
    ) %>%
    mutate(match_key_used = tier_name)
}

matched_icao <- join_tier(crosswalk, mshr, "icao_faa_std", "icao_faa_std", "ICAO/FAA")
remaining_1  <- anti_join(crosswalk, matched_icao, by = "station_uid")

matched_wban <- join_tier(remaining_1, mshr, "wban_std", "wban_std", "USAF/WBAN")
remaining_2  <- anti_join(remaining_1, matched_wban, by = "station_uid")

matched_wmo  <- join_tier(remaining_2, mshr, "wmo_std", "wmo_std", "WMO")
unmatched    <- anti_join(remaining_2, matched_wmo, by = "station_uid")

if (nrow(unmatched) > 0) {
  message(
    nrow(unmatched), " of ", nrow(crosswalk),
    " crosswalk stations could not be matched to Enhanced MSHR on any key ",
    "(ICAO/FAA, USAF/WBAN, or WMO) and are excluded from the terrain audit ",
    "(no coordinates to work with). See unmatched_crosswalk_stations.csv."
  )
  readr::write_csv(unmatched, file.path(data_processed_dir, "unmatched_crosswalk_stations.csv"))
}

stations <- bind_rows(matched_icao, matched_wban, matched_wmo) %>%
  mutate(
    state = dplyr::coalesce(state_cw, state_mshr),
    station_name = dplyr::coalesce(name_cw, name_mshr),
    # Prefer the crosswalk's own lat/lon when it has them (this one does)
    # -- it is the more current, purpose-built source for this study --
    # and fall back to MSHR's only where the crosswalk lacks them.
    lat = dplyr::coalesce(lat_cw, lat),
    lon = dplyr::coalesce(lon_cw, lon),
    # Same preference for period of record: the crosswalk's own dates are
    # real ISH/GHCNh data-period bounds, not MSHR's "still active" sentinel,
    # so they need no sentinel handling -- only MSHR's do.
    begin_date_cw = suppressWarnings(lubridate::ymd(begin_date_cw_raw)),
    end_date_cw   = suppressWarnings(lubridate::ymd(end_date_cw_raw)),
    por_source_is_cw = !is.na(begin_date_cw) & !is.na(end_date_cw),
    begin_date_mshr = suppressWarnings(lubridate::ymd(begin_date_raw)),
    end_date_mshr = dplyr::if_else(
      end_date_raw %in% c("99991231", "9999-12-31", "", NA_character_),
      Sys.Date(),
      suppressWarnings(lubridate::ymd(end_date_raw))
    ),
    begin_date = dplyr::if_else(por_source_is_cw, begin_date_cw, begin_date_mshr),
    end_date   = dplyr::if_else(por_source_is_cw, end_date_cw, end_date_mshr),
    por_days = as.numeric(end_date - begin_date),
    por_source = dplyr::if_else(por_source_is_cw, "crosswalk", "MSHR"),
    # Crosswalk's own platform reading (ASOS/AWOS), preferred over MSHR's.
    platform = dplyr::coalesce(platform_cw, platform),
    # Flag rows the crosswalk itself already marked as a weak or unverified
    # match (e.g. no isd-history match, or a coordinate-mismatch note), so
    # Step 5 does not prefer one of these as the "clean" pick.
    crosswalk_match_issue_flag = (match_method_cw %in% c("UNMATCHED")) |
      (!is.na(notes_cw) & notes_cw != "")
  ) %>%
  filter(state %in% conus_states)

message("Stations with MSHR coordinates in the lower 48 + DC: ", nrow(stations))

missing_states <- setdiff(conus_states, unique(stations$state))
if (length(missing_states) > 0) {
  message(
    "No matched, coordinate-bearing crosswalk station found for: ",
    paste(missing_states, collapse = ", "),
    ". These states will be absent from the final table rather than filled ",
    "with a fabricated pick."
  )
}


# =======================================================================
# STEP 3: Terrain classification
# =======================================================================
# Three complex-terrain mechanisms are tested independently, then
# combined into complex_flag = coastal OR mountain OR river.
#   coastal:  distance to shoreline/Great Lakes <= coastal_km
#   mountain: relief within mountain_radius_km >= mountain_relief_m
#   river:    distance to a major river <= river_km AND relief within
#             river_radius_km >= river_relief_m -- proximity alone is
#             not enough, a station on a river in flat terrain should
#             not trip this flag
# A station with none of the three, and low background relief, is
# tagged "simple".

# --- 3a. Coastline + Great Lakes (cached under data_raw_dir) --------------
coastline <- tryCatch({
  rnaturalearth::ne_download(
    scale = 50, type = "coastline", category = "physical",
    destdir = data_raw_dir, load = TRUE, returnclass = "sf"
  )
}, error = function(e) {
  stop("Could not obtain the Natural Earth coastline layer: ", conditionMessage(e),
       call. = FALSE)
})
log_download("ne_50m_coastline", "rnaturalearth::ne_download(type='coastline')",
              file.path(data_raw_dir, "ne_50m_coastline.shp"))

lakes <- tryCatch({
  rnaturalearth::ne_download(
    scale = 50, type = "lakes", category = "physical",
    destdir = data_raw_dir, load = TRUE, returnclass = "sf"
  )
}, error = function(e) {
  stop("Could not obtain the Natural Earth lakes layer (needed for Great Lakes shoreline): ",
       conditionMessage(e), call. = FALSE)
})
log_download("ne_50m_lakes", "rnaturalearth::ne_download(type='lakes')",
              file.path(data_raw_dir, "ne_50m_lakes.shp"))

# Crop to CONUS before any heavy geometry operations -- ne_download()
# returns whole-world layers, and cropping first keeps st_union()/
# st_distance() fast without changing which stations are near which
# features (conus_bbox comfortably contains the lower 48 + DC).
conus_bbox_sfc <- sf::st_as_sfc(sf::st_bbox(conus_bbox, crs = sf::st_crs(4326)))
coastline <- suppressWarnings(sf::st_crop(coastline, conus_bbox_sfc))
lakes     <- suppressWarnings(sf::st_crop(lakes, conus_bbox_sfc))

great_lakes <- lakes %>%
  filter(name %in% c("Lake Superior", "Lake Michigan", "Lake Huron", "Lake Erie", "Lake Ontario"))
if (nrow(great_lakes) == 0) {
  warning("No Great Lakes matched by name in the Natural Earth lakes layer; the coastal ",
          "test will run on the ocean coastline only. Check the 'name' field in ",
          "ne_50m_lakes if Great Lakes stations need this.", call. = FALSE)
}

# Combine as geometries (sfc), not data frames -- coastline is lines and
# Great Lakes are polygons, and c() on two sfc objects handles mixed
# geometry types cleanly where bind_rows()/rbind() on sf data frames can
# trip over the type mismatch.
water_boundary <- c(st_geometry(coastline), st_geometry(great_lakes)) %>%
  st_transform(5070) %>%  # CONUS Albers equal-area, meters
  st_union()  # one geometry, so each station only needs one st_distance() call

# --- 3b. Major rivers -------------------------------------------------------
rivers <- tryCatch({
  rnaturalearth::ne_download(
    scale = 10, type = "rivers_lake_centerlines", category = "physical",
    destdir = data_raw_dir, load = TRUE, returnclass = "sf"
  )
}, error = function(e) {
  stop("Could not obtain the Natural Earth rivers layer: ", conditionMessage(e), call. = FALSE)
})
log_download("ne_10m_rivers_lake_centerlines",
              "rnaturalearth::ne_download(type='rivers_lake_centerlines')",
              file.path(data_raw_dir, "ne_10m_rivers_lake_centerlines.shp"))

rivers <- suppressWarnings(sf::st_crop(rivers, conus_bbox_sfc))

major_rivers <- rivers %>%
  filter(scalerank <= river_scalerank_max) %>%
  st_transform(5070) %>%
  st_geometry() %>%
  st_union()  # one geometry, so each station only needs one st_distance() call

# --- 3c. DEM (cached as a single CONUS-wide raster) ------------------------
dem_cache_path <- file.path(data_raw_dir, paste0("conus_dem_z", dem_z, ".tif"))
dem <- tryCatch({
  if (file.exists(dem_cache_path)) {
    message("Using cached DEM: ", dem_cache_path)
    terra::rast(dem_cache_path)
  } else {
    message("Downloading CONUS DEM at zoom ", dem_z, " via elevatr (can take a few minutes)...")
    conus_bbox_pts <- data.frame(x = c(conus_bbox[["xmin"]], conus_bbox[["xmax"]]),
                                  y = c(conus_bbox[["ymin"]], conus_bbox[["ymax"]]))
    dem_raw <- elevatr::get_elev_raster(locations = conus_bbox_pts, prj = 4326, z = dem_z, clip = "bbox")
    dem_proj <- terra::project(terra::rast(dem_raw), "EPSG:5070")
    terra::writeRaster(dem_proj, dem_cache_path, overwrite = TRUE)
    dem_proj
  }
}, error = function(e) {
  stop("Could not obtain the CONUS elevation raster via elevatr: ", conditionMessage(e),
       "\nCheck network access and the elevatr/AWS Terrain Tiles service.", call. = FALSE)
})
log_download(basename(dem_cache_path), "elevatr::get_elev_raster (AWS Terrain Tiles)", dem_cache_path)

# --- 3d. Compute terrain metrics per station -------------------------------
stations_sf <- stations %>%
  st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE) %>%
  st_transform(5070)

stations_sf <- stations_sf %>%
  mutate(
    dist_coast_km = as.numeric(st_distance(., water_boundary)) / 1000,
    dist_river_km = as.numeric(st_distance(., major_rivers)) / 1000,
    relief_mountain_radius_m = relief_in_radius(dem, ., mountain_radius_km),
    relief_river_radius_m    = relief_in_radius(dem, ., river_radius_km)
  )

stations <- stations_sf %>%
  st_drop_geometry() %>%
  mutate(
    coastal_flag       = dist_coast_km <= coastal_km,
    coastal_flag_20km  = dist_coast_km <= coastal_km_sensitivity,  # sensitivity column only
    mountain_flag      = !is.na(relief_mountain_radius_m) & relief_mountain_radius_m >= mountain_relief_m,
    river_flag         = !is.na(relief_river_radius_m) & dist_river_km <= river_km &
                          relief_river_radius_m >= river_relief_m,
    complex_flag       = coastal_flag | mountain_flag | river_flag,
    simple_flag        = !complex_flag &
                          !is.na(relief_mountain_radius_m) &
                          relief_mountain_radius_m <= simple_relief_max_m
  )

mechanism_label <- function(coastal, mountain, river) {
  parts <- c(
    if (isTRUE(coastal)) "coastal",
    if (isTRUE(mountain)) "mountain",
    if (isTRUE(river)) "river"
  )
  if (length(parts) == 0) "simple" else paste(parts, collapse = "+")
}
stations$subtype <- purrr::pmap_chr(
  list(stations$coastal_flag, stations$mountain_flag, stations$river_flag),
  mechanism_label
)

# Complexity score used to rank complex candidates: mechanism count
# dominates, then how far past each threshold a station sits (so a
# station deep in the mountains outranks one barely over 300 m).
stations <- stations %>%
  mutate(
    n_mechanisms     = coastal_flag + mountain_flag + river_flag,
    coastal_margin   = pmax(0, coastal_km - dist_coast_km) / coastal_km,
    mountain_margin  = ifelse(
      is.na(relief_mountain_radius_m), 0,
      pmax(0, (relief_mountain_radius_m - mountain_relief_m) / mountain_relief_m)
    ),
    river_margin     = ifelse(!is.na(relief_river_radius_m) & river_flag,
                               pmax(0, (relief_river_radius_m - river_relief_m) / river_relief_m), 0),
    complexity_score = n_mechanisms * 10 + coastal_margin + mountain_margin + river_margin,
    # barrier/outlier flags added in Step 4
    flag_count       = coastal_flag + mountain_flag + river_flag + crosswalk_match_issue_flag,
    min_feature_dist_km = pmin(dist_coast_km, dist_river_km, na.rm = TRUE)
  )


# =======================================================================
# STEP 4: RAOB pairing (IGRA v2)
# =======================================================================

# --- 4a. Download IGRA station list (cached) -------------------------------
igra_path <- file.path(data_raw_dir, "igra2-station-list.txt")
tryCatch({
  cache_download(igra_list_url, igra_path, validate = validate_igra_content)
  log_download("igra2-station-list.txt", igra_list_url, igra_path, get_last_modified(igra_list_url))
}, error = function(e) stop(conditionMessage(e), call. = FALSE))

# --- 4b. Parse fixed-width IGRA station list --------------------------------
# Column positions per the IGRA v2 station-list documentation:
#   ID 1-11, lat 13-20, lon 22-30, elev 32-37, state 39-40,
#   name 42-71, fstyear 73-76, lstyear 78-81
igra <- readr::read_fwf(
  igra_path,
  col_positions = readr::fwf_cols(
    id      = c(1, 11),
    lat     = c(13, 20),
    lon     = c(22, 30),
    elev_m  = c(32, 37),
    state   = c(39, 40),
    name    = c(42, 71),
    fstyear = c(73, 76),
    lstyear = c(78, 81)
  ),
  col_types = readr::cols(
    id = "c", lat = "d", lon = "d", elev_m = "d", state = "c",
    name = "c", fstyear = "i", lstyear = "i"
  ),
  trim_ws = TRUE
)
message("Loaded IGRA v2 station list: ", nrow(igra), " stations.")

raob <- igra %>%
  filter(stringr::str_starts(id, "US"), lstyear >= raob_active_since)
message("Active US RAOB stations (lstyear >= ", raob_active_since, "): ", nrow(raob))

if (nrow(raob) == 0) {
  stop("No active US RAOB stations found in the IGRA list with lstyear >= ",
       raob_active_since, ". Check raob_active_since and the IGRA file.", call. = FALSE)
}

# --- 4c. Nearest RAOB per surface station -----------------------------------
dist_matrix_m <- geosphere::distm(
  cbind(stations$lon, stations$lat),
  cbind(raob$lon, raob$lat),
  fun = geosphere::distGeo
)
nearest_idx <- apply(dist_matrix_m, 1, which.min)

stations <- stations %>%
  mutate(
    raob_id      = raob$id[nearest_idx],
    raob_name    = raob$name[nearest_idx],
    raob_lat     = raob$lat[nearest_idx],
    raob_lon     = raob$lon[nearest_idx],
    raob_elev_m  = raob$elev_m[nearest_idx],
    raob_dist_km = apply(dist_matrix_m, 1, min) / 1000,
    barrier_review_flag = abs(elev_m - raob_elev_m) > raob_elev_diff_m,
    dist_outlier_flag = raob_dist_km > stats::quantile(raob_dist_km, dist_outlier_pctile, na.rm = TRUE),
    flag_count = flag_count + barrier_review_flag + dist_outlier_flag
  )


# =======================================================================
# STEP 5: Per-state selection
# =======================================================================
# platform tie-break: ASOS ranks above AWOS above anything else/unknown.
# If mshr_cols$platform did not resolve to a real column (see Step 2),
# platform is all-NA and platform_rank is 3 for every station, so this
# tie-break has no effect and selection falls through to station_uid.
stations <- stations %>%
  mutate(
    platform_rank = dplyr::case_when(
      stringr::str_detect(toupper(dplyr::coalesce(platform, "")), "ASOS") ~ 1,
      stringr::str_detect(toupper(dplyr::coalesce(platform, "")), "AWOS") ~ 2,
      TRUE ~ 3
    )
  )

# --- 5a. Simple-terrain pick per state ---------------------------------------
# Ranked by: fewest flags, lowest local relief, farthest from coast/river,
# then tie-broken by longer period of record, ASOS over AWOS, and finally
# station_uid for a fully deterministic result.
simple_pick <- stations %>%
  group_by(state) %>%
  arrange(
    flag_count, relief_mountain_radius_m, dplyr::desc(min_feature_dist_km),
    dplyr::desc(por_days), platform_rank, station_uid,
    .by_group = TRUE
  ) %>%
  slice(1) %>%
  ungroup() %>%
  mutate(
    terrain_class = "simple",
    below_simple_threshold_flag = flag_count > 0,
    selection_reason = glue::glue(
      "Simple-terrain pick: {flag_count} terrain flag(s), relief within ",
      "{mountain_radius_km} km = {round(relief_mountain_radius_m, 0)} m, ",
      "distance to nearest coast/river = {round(min_feature_dist_km, 1)} km ",
      "(farthest available in state), POR = {round(por_days, 0)} days, ",
      "match key = {match_key_used}.",
      "{ifelse(below_simple_threshold_flag, ' NOTE: every candidate station in this state carries at least one flag; this is the least-complex available, not a clean simple site.', '')}",
      "{ifelse(crosswalk_match_issue_flag, ' NOTE: the crosswalk itself flagged this station (', '')}",
      "{ifelse(crosswalk_match_issue_flag, paste0(dplyr::coalesce(match_method_cw, ''), ifelse(!is.na(notes_cw) & notes_cw != '', paste0('; ', notes_cw), ''), ') -- verify manually.'), '')}"
    )
  )

# --- 5b. Complex-terrain pick per state --------------------------------------
# desc(complex_flag) guarantees a flagged station wins whenever the state
# has one; within that, highest complexity_score wins. If no station in
# the state clears any threshold, the ranking still resolves to the
# most-complex-available station and below_complex_threshold_flag records
# that it did not actually clear a threshold.
complex_pick <- stations %>%
  group_by(state) %>%
  arrange(
    dplyr::desc(complex_flag), dplyr::desc(complexity_score),
    dplyr::desc(por_days), platform_rank, station_uid,
    .by_group = TRUE
  ) %>%
  slice(1) %>%
  ungroup() %>%
  mutate(
    terrain_class = "complex",
    below_complex_threshold_flag = !complex_flag,
    selection_reason = glue::glue(
      "Complex-terrain pick: mechanism(s) = {subtype}, relief within ",
      "{mountain_radius_km} km = {round(relief_mountain_radius_m, 0)} m, ",
      "distance to coast = {round(dist_coast_km, 1)} km, distance to river = ",
      "{round(dist_river_km, 1)} km, strongest available in state, ",
      "match key = {match_key_used}.",
      "{ifelse(below_complex_threshold_flag, ' NOTE: no candidate station in this state cleared any complex-terrain threshold; this is the most-complex-available, not a confirmed complex site.', '')}",
      "{ifelse(crosswalk_match_issue_flag, ' NOTE: the crosswalk itself flagged this station (', '')}",
      "{ifelse(crosswalk_match_issue_flag, paste0(dplyr::coalesce(match_method_cw, ''), ifelse(!is.na(notes_cw) & notes_cw != '', paste0('; ', notes_cw), ''), ') -- verify manually.'), '')}"
    )
  )

station_audit_table <- bind_rows(simple_pick, complex_pick) %>%
  arrange(state, terrain_class) %>%
  select(
    state, terrain_class, subtype, selection_reason,
    station_name, usaf_std, wban_std, wmo_std, icao_faa_std, match_key_used,
    lat, lon, elev_m, utc_offset, begin_date, end_date, por_days, por_source, platform,
    dist_coast_km, coastal_flag, coastal_flag_20km,
    dist_river_km, relief_river_radius_m, river_flag,
    relief_mountain_radius_m, mountain_flag,
    complex_flag, n_mechanisms, complexity_score,
    below_complex_threshold_flag, below_simple_threshold_flag,
    raob_id, raob_name, raob_lat, raob_lon, raob_elev_m, raob_dist_km,
    barrier_review_flag, dist_outlier_flag,
    crosswalk_match_issue_flag, match_method_cw, notes_cw,
    ish_filename, ghcnh_filename, ghcn_id,
    flag_count, station_uid
  )

message(
  "Final table: ", nrow(station_audit_table), " rows across ",
  dplyr::n_distinct(station_audit_table$state), " states (expect up to ",
  length(conus_states) * 2, ")."
)


# =======================================================================
# STEP 6: Write CSV and provenance README
# =======================================================================
csv_path <- file.path(data_processed_dir, "station_audit_table.csv")
readr::write_csv(station_audit_table, csv_path)
message("Wrote ", csv_path)

# --- Build the README from what actually happened in this run --------------
download_entries <- mget(ls(download_log), envir = download_log)
download_lines <- purrr::imap_chr(download_entries, function(entry, nm) {
  # .trim = FALSE: glue() otherwise strips the common leading whitespace
  # from every line, which would flatten these into top-level bullets
  # instead of nested ones.
  glue::glue(
    "- **{nm}**\n",
    "  - source: {entry$url}\n",
    "  - cached at: {entry$path}\n",
    "  - retrieved: {entry$retrieved_at}\n",
    "  - local file timestamp: {entry$file_mtime}\n",
    "  - server Last-Modified (if reported): {entry$source_last_modified}",
    .trim = FALSE
  )
})

param_lines <- glue::glue(
  "- coastal_km = {coastal_km} (sensitivity column at {coastal_km_sensitivity} km)\n",
  "- mountain_relief_m = {mountain_relief_m}, mountain_radius_km = {mountain_radius_km}\n",
  "- river_km = {river_km}, river_relief_m = {river_relief_m}, river_radius_km = {river_radius_km}\n",
  "- simple_relief_max_m = {simple_relief_max_m}\n",
  "- river_scalerank_max = {river_scalerank_max} (Natural Earth rivers_lake_centerlines)\n",
  "- raob_active_since = {raob_active_since}\n",
  "- raob_elev_diff_m (barrier_review_flag proxy) = {raob_elev_diff_m}\n",
  "- dist_outlier_pctile = {dist_outlier_pctile}\n",
  "- dem_z = {dem_z} (elevatr / AWS Terrain Tiles zoom level)"
)

session_info_text <- paste(utils::capture.output(utils::sessionInfo()), collapse = "\n")

readme_text <- glue::glue(
  "# Station Selection Audit -- Provenance\n\n",
  "Generated {Sys.time()} by R/station_selection_audit.R.\n\n",
  "## What this is\n",
  "One simple-terrain and one complex-terrain surface station per state ",
  "(lower 48 + DC), each drawn from the crosswalk at `{crosswalk_path}`, ",
  "tagged by terrain mechanism, and paired to the nearest active US RAOB ",
  "station from IGRA v2. Every row traces to a named source file listed ",
  "below; nothing in this table was fabricated.\n\n",
  "## Source files\n\n{paste(download_lines, collapse = '\\n\\n')}\n\n",
  "## Thresholds used in this run\n\n{param_lines}\n\n",
  "## Column-name assumptions\n",
  "This run mapped the crosswalk and Enhanced MSHR files to internal roles ",
  "using the `crosswalk_cols` and `mshr_cols` lists at the top of the ",
  "script. Any mismatch between those guessed names and the real files ",
  "would have stopped the run with an error listing the real column names ",
  "-- if you are reading this README, the mapping in effect for this run ",
  "was:\n\n",
  "Crosswalk: {paste(names(crosswalk_cols), unlist(crosswalk_cols), sep = ' = ', collapse = ', ')}\n\n",
  "MSHR: {paste(names(mshr_cols), unlist(mshr_cols), sep = ' = ', collapse = ', ')}\n\n",
  "## Coverage\n",
  "{nrow(unmatched)} of {nrow(crosswalk)} crosswalk stations could not be ",
  "matched to Enhanced MSHR on ICAO/FAA, USAF/WBAN, or WMO and were excluded ",
  "(see unmatched_crosswalk_stations.csv if non-zero). ",
  "{ifelse(length(missing_states) > 0, paste0('No usable station was found for: ', paste(missing_states, collapse = ', '), '.'), 'A candidate was found for every state in scope.')}\n\n",
  "## Known limitations\n",
  "- **Coarse DEM**: dem_z = {dem_z} understates relief in narrow valleys ",
  "and canyons; a station can test as 'simple' here and still sit in ",
  "genuinely complex terrain on the ground. Sanity-check borderline picks ",
  "against a topographic map.\n",
  "- **Smoothed shoreline and river geometry**: Natural Earth's 1:50m ",
  "coastline/lakes and 1:10m rivers are generalized lines, not surveyed ",
  "boundaries; distance-to-feature figures near the thresholds (10 km ",
  "coastal, 5 km river) can be off by a station or two along complex ",
  "shorelines or river deltas.\n",
  "- **Sea breeze can exceed 10 km**: coastal_km = {coastal_km} is a ",
  "screening threshold, not a physical limit on sea-breeze influence; ",
  "the {coastal_km_sensitivity} km sensitivity column is provided for ",
  "reviewing borderline cases.\n",
  "- **Forced one-complex-per-state pick**: below_complex_threshold_flag ",
  "marks states where no station actually cleared a complex-terrain ",
  "threshold, so the 'complex' pick is only the most-complex-available, ",
  "not a confirmed complex site. below_simple_threshold_flag marks the ",
  "mirror case on the simple side.\n",
  "- **barrier_review_flag is a proxy**: a large surface-to-RAOB elevation ",
  "difference (> {raob_elev_diff_m} m) flags a pairing for human review; ",
  "it is not a real terrain-barrier (e.g. ridge-line) analysis.\n",
  "- **ASOS/AWOS tie-break depends on some source carrying a usable platform ",
  "field** (the crosswalk's own, else MSHR's): if neither resolved to a real, ",
  "non-'UNKNOWN' value for a given station, that tie-break silently had no ",
  "effect for it (see the optional-column warnings printed during this run).\n",
  "- **lat/lon/period-of-record/platform are preferred from the crosswalk** ",
  "when it supplies them, falling back to Enhanced MSHR only where the ",
  "crosswalk does not; por_source records which one won for each row. ",
  "Elevation, UTC offset, state, and WMO always come from MSHR, since the ",
  "crosswalk is not assumed to carry them.\n",
  "- **crosswalk_match_issue_flag** marks a station the crosswalk itself ",
  "already flagged as a weak or unverified match (its own match_method/notes ",
  "columns, if present) -- it feeds into flag_count so such a station is not ",
  "preferred as the 'clean' pick, but it is still eligible if nothing better ",
  "is available in that state.\n",
  "- **Enhanced MSHR and IGRA source URLs were not confirmed live** by the ",
  "environment that authored this script (no network access to ",
  "ncei.noaa.gov). If a download step above failed, update the URL ",
  "parameters at the top of the script from the current HOMR reports page.\n\n",
  "## sessionInfo()\n\n```\n{session_info_text}\n```\n"
)

readme_path <- file.path(data_processed_dir, "README.md")
writeLines(readme_text, readme_path)
message("Wrote ", readme_path)


# =======================================================================
# STEP 7 (optional): Leaflet QA map, colored by terrain class
# =======================================================================
pal <- leaflet::colorFactor(c("#2b8a3e", "#c92a2a"), domain = c("simple", "complex"))

map <- leaflet::leaflet(station_audit_table) %>%
  leaflet::addProviderTiles(leaflet::providers$CartoDB.Positron) %>%
  leaflet::addCircleMarkers(
    lng = ~lon, lat = ~lat,
    color = ~pal(terrain_class),
    radius = 6, stroke = FALSE, fillOpacity = 0.85,
    popup = ~glue::glue(
      "<b>{state} -- {terrain_class}</b><br>",
      "{station_name}<br>",
      "subtype: {subtype}<br>",
      "USAF/WBAN: {usaf_std}/{wban_std} | WMO: {wmo_std} | ICAO/FAA: {icao_faa_std}<br>",
      "nearest RAOB: {raob_name} ({raob_id}), {round(raob_dist_km, 0)} km<br>",
      "{selection_reason}"
    )
  ) %>%
  leaflet::addLegend(
    position = "bottomright", pal = pal, values = c("simple", "complex"),
    title = "Terrain class"
  )

map_path <- file.path(output_dir, "station_map.html")
htmlwidgets::saveWidget(map, map_path, selfcontained = TRUE)
message("Wrote ", map_path)

message("Done. See ", csv_path, ", ", readme_path, ", and ", map_path, ".")

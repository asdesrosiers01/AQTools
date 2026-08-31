# =====================================================================
# generate_fixtures.R
#
# Builds small, clearly-synthetic test fixtures for
# R/station_selection_audit.R: a fake crosswalk, a fake Enhanced MSHR
# extract, and a fake IGRA station list, matching the file formats and
# default column-name assumptions the real script expects.
#
# These fixtures exist ONLY to sanity-check the script's plumbing (column
# validation, cascading joins, standardization, flagging, tie-breaks,
# README generation) before running against real data. Coordinates and
# elevations are approximate/rounded, several rows are labeled SYNTHETIC
# and do not correspond to any real station, and periods of record are
# invented. Do not use this output for any actual AERMET analysis.
#
# Run once: Rscript generate_fixtures.R  (writes into this directory)
# =====================================================================
library(readr)
library(dplyr)

set.seed(42)
# Run this script with the working directory set to this fixtures folder
# (e.g. `cd data/raw/test_fixtures && Rscript generate_fixtures.R`).
here <- "."

# -----------------------------------------------------------------
# 1. Fake crosswalk -- covers: a normal multi-station state (NY, CO,
#    FL), a single-station state (DC, so simple_pick == complex_pick
#    is exercised deliberately), a WBAN-only join tier case, a
#    WMO-only join tier case, and one row with bogus identifiers that
#    cannot match anything (exercises the unmatched-station path).
# -----------------------------------------------------------------
crosswalk <- tribble(
  ~WMO,    ~ICAO,  ~FAA,   ~USAF,    ~WBAN,  ~STATE, ~STATION_NAME,
  "74486", "KJFK", "KJFK", "744860", "94789", "NY",  "JFK INTERNATIONAL AIRPORT",
  "72518", "KALB", "KALB", "725180", "14735", "NY",  "ALBANY INTERNATIONAL AIRPORT",
  "72565", "KDEN", "KDEN", "725650", "03017", "CO",  "DENVER INTERNATIONAL AIRPORT",
  NA,      "KAKO", "KAKO", "724635", "94018", "CO",  "COLORADO PLAINS RGNL AIRPORT",
  "72202", "KMIA", "KMIA", "722020", "12839", "FL",  "MIAMI INTERNATIONAL AIRPORT",
  "72214", "KTLH", "KTLH", "722140", "93805", "FL",  "TALLAHASSEE INTERNATIONAL AIRPORT",
  "72405", "KDCA", "KDCA", "724050", "13743", "DC",  "RONALD REAGAN WASHINGTON NATL AIRPORT",
  NA,      NA,     NA,     NA,       "14750", "NY",  "SYNTHETIC WBAN-ONLY TEST STATION",
  "72469", NA,     NA,     NA,       NA,      "CO",  "SYNTHETIC WMO-ONLY TEST STATION",
  "00000", "ZZZZ", "ZZZZ", "000000", "00000", "FL",  "SYNTHETIC UNMATCHED TEST STATION"
)
write_csv(crosswalk, file.path(here, "station_crosswalk_sample.csv"))

# -----------------------------------------------------------------
# 2. Fake Enhanced MSHR extract -- pipe-delimited, matching the
#    default mshr_cols mapping in the real script. Approximate real
#    coordinates/elevations for the named airports; invented values
#    for the SYNTHETIC rows. PLATFORM varies to exercise the
#    ASOS-over-AWOS tie-break.
# -----------------------------------------------------------------
mshr <- tribble(
  ~ICAO_ID, ~FAA_ID, ~WBAN_ID, ~WMO_ID, ~LAT_DEC, ~LON_DEC,  ~ELEV_GROUND, ~UTC_OFFSET, ~STATE_PROV, ~NAME_PRINCIPAL,                          ~BEGIN_DATE, ~END_DATE,  ~PLATFORM,
  "KJFK",   "KJFK",  "94789",  "74486", 40.6398,  -73.7789,  4,            -5,          "NY",        "JFK INTERNATIONAL AIRPORT",              "19480101",  "99991231", "ASOS",
  "KALB",   "KALB",  "14735",  "72518", 42.7483,  -73.8017,  87,           -5,          "NY",        "ALBANY INTERNATIONAL AIRPORT",           "19380101",  "99991231", "ASOS",
  "KDEN",   "KDEN",  "03017",  "72565", 39.8617,  -104.6731, 1655,         -7,          "CO",        "DENVER INTERNATIONAL AIRPORT",           "19950101",  "99991231", "ASOS",
  "KAKO",   "KAKO",  "94018",  NA,      40.1747,  -103.2213, 1354,         -7,          "CO",        "COLORADO PLAINS RGNL AIRPORT",           "19730101",  "99991231", "AWOS",
  "KMIA",   "KMIA",  "12839",  "72202", 25.7959,  -80.2870,  2,            -5,          "FL",        "MIAMI INTERNATIONAL AIRPORT",            "19480101",  "99991231", "ASOS",
  "KTLH",   "KTLH",  "93805",  "72214", 30.3965,  -84.3503,  22,           -5,          "FL",        "TALLAHASSEE INTERNATIONAL AIRPORT",      "19730101",  "99991231", "ASOS",
  "KDCA",   "KDCA",  "13743",  "72405", 38.8512,  -77.0402,  4,            -5,          "DC",        "RONALD REAGAN WASHINGTON NATL AIRPORT",  "19410101",  "99991231", "ASOS",
  NA,       NA,      "14750",  NA,      42.9000,  -73.8000,  130,          -5,          "NY",        "SYNTHETIC WBAN-ONLY TEST STATION",       "20050101",  "99991231", "AWOS",
  NA,       NA,      NA,       "72469", 39.9000,  -104.3000, 1450,         -7,          "CO",        "SYNTHETIC WMO-ONLY TEST STATION",        "19900101",  "20151231", "ASOS"
)
write_delim(mshr, file.path(here, "MSHR_Enhanced_Table_sample.txt"), delim = "|", na = "")

# -----------------------------------------------------------------
# 3. Fake IGRA v2 station list -- fixed-width, exact column positions
#    per the real spec (id 1-11, lat 13-20, lon 22-30, elev 32-37,
#    state 39-40, name 42-71, fstyear 73-76, lstyear 78-81). Built by
#    placing fields into a blank-padded character buffer at those
#    exact offsets so the widths cannot drift out of sync by hand.
# -----------------------------------------------------------------
raob <- tribble(
  ~id,           ~lat,    ~lon,      ~elev, ~state, ~name,                          ~fstyear, ~lstyear,
  "USM00072518", 42.6900, -73.8300,  87.0,  "NY",   "ALBANY NY",                     1948,     2025,
  "USM00072469", 39.7749, -104.8788, 1611.0,"CO",   "DENVER STAPLETON CO",           1948,     2025,
  "USM00072202", 25.9000, -80.4000,  3.0,   "FL",   "MIAMI FL",                      1948,     2025,
  "USM00072403", 38.9800, -77.4700,  85.0,  "VA",   "STERLING DULLES VA",            1948,     2025,
  "USM00072520", 40.8600, -78.0000,  320.0, "PA",   "STATE COLLEGE PA",              1948,     1999   # inactive: lstyear < 2024, must be excluded
)

pad_line <- function(row) {
  buf <- strrep(" ", 90)
  set_field <- function(buf, start, stop, value) {
    value <- as.character(value)
    field_width <- stop - start + 1
    if (nchar(value) > field_width) value <- substr(value, 1, field_width)
    substr(buf, start, start + nchar(value) - 1) <- value
    buf
  }
  buf <- set_field(buf, 1, 11, row$id)
  buf <- set_field(buf, 13, 20, formatC(row$lat, format = "f", digits = 4, width = 8))
  buf <- set_field(buf, 22, 30, formatC(row$lon, format = "f", digits = 4, width = 9))
  buf <- set_field(buf, 32, 37, formatC(row$elev, format = "f", digits = 1, width = 6))
  buf <- set_field(buf, 39, 40, row$state)
  buf <- set_field(buf, 42, 71, row$name)
  buf <- set_field(buf, 73, 76, row$fstyear)
  buf <- set_field(buf, 78, 81, row$lstyear)
  buf
}

igra_lines <- vapply(seq_len(nrow(raob)), function(i) pad_line(raob[i, ]), character(1))
writeLines(igra_lines, file.path(here, "igra2-station-list_sample.txt"))

message("Wrote fixtures to ", here)
message("  station_crosswalk_sample.csv: ", nrow(crosswalk), " rows")
message("  MSHR_Enhanced_Table_sample.txt: ", nrow(mshr), " rows")
message("  igra2-station-list_sample.txt: ", nrow(raob), " rows (1 deliberately inactive)")

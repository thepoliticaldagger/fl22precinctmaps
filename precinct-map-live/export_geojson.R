# ------------------------------------------------------------------
# EXPORT STATIC LAYERS FOR THE LIVE WEB MAP
#
# This replaces the old all-in-one R/Leaflet script.
#
# It builds three STATIC layers (they don't change during the
# election cycle, so we bake them into GeoJSON once):
#   1. Demographics (Census VAP)
#   2. 2020 Election results
#   3. 2024 Election results
#
# The 4th layer — Early/Mail Voting — is NOT built here anymore.
# It's fetched LIVE, in the browser, from the county JSON feeds:
#   https://s3.amazonaws.com/turnoutquickview.electionsfl.org/data/FL/CLL/132/data.json
#   https://s3.amazonaws.com/turnoutquickview.electionsfl.org/data/FL/HEN/112/data.json
#   https://s3.amazonaws.com/turnoutquickview.electionsfl.org/data/FL/PAL/578/data.json
#
# Re-run this script only when the precinct shapefile, Census data,
# or election results shapefiles change. You do NOT need to re-run
# it for turnout updates — that's handled live by the web page.
#
# Run this once, then copy the three .geojson files it creates
# into precinct-map-live/data/ (this script writes them there
# directly if run from inside that folder — otherwise adjust
# `out_dir` below).
# ------------------------------------------------------------------

# install.packages(c(
#   "sf", "tidycensus", "tigris", "dplyr", "tidyr"
# ))

library(sf)
library(tidycensus)
library(tigris)
library(dplyr)
library(tidyr)

# census_api_key("YOUR_KEY_HERE", install = TRUE)   # one-time setup

options(tigris_use_cache = TRUE)

out_dir <- "data"   # change if you're not running this from inside precinct-map-live/
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)


# ==============================================================
# 1. LOAD YOUR RAW PRECINCT SHAPEFILE
# ==============================================================

precinct_shp_path <- file.choose()

precincts <- st_read(precinct_shp_path, quiet = FALSE)

precincts <- st_zm(precincts, drop = TRUE, what = "ZM")

cat("\nMain precinct shapefile columns:\n")
print(names(precincts))

# --------------------------------------------------------------
# MAIN PRECINCT ID
# --------------------------------------------------------------
# Three counties use "PRECINCT". Collier uses "Name" formatted
# as "Precinct 101" instead.

precinct_col_primary  <- "PRECINCT"
precinct_col_fallback <- "Name"

for (col in c(precinct_col_primary, precinct_col_fallback)) {
  if (!col %in% names(precincts)) {
    stop(
      "Column '", col, "' not found in main precinct shapefile.\n\n",
      "Available columns:\n",
      paste(names(precincts), collapse = ", ")
    )
  }
}

precincts <- precincts %>%
  mutate(
    PRECINCT_ID = dplyr::coalesce(
      dplyr::na_if(trimws(as.character(.data[[precinct_col_primary]])), ""),
      dplyr::na_if(
        trimws(
          sub(
            "^precinct\\s+", "",
            as.character(.data[[precinct_col_fallback]]),
            ignore.case = TRUE
          )
        ),
        ""
      )
    )
  )

precinct_id_col <- "PRECINCT_ID"

# --------------------------------------------------------------
# NORMALIZED PRECINCT ID (must match the live turnout JSON keys,
# e.g. "132.0" -> "132")
# --------------------------------------------------------------

normalize_precinct <- function(x) {
  x <- trimws(as.character(x))
  x <- sub("\\.[0-9]+$", "", x)
  numeric_ok <- grepl("^[0-9]+$", x)
  x[numeric_ok] <- as.character(as.integer(x[numeric_ok]))
  x
}

precincts$precinct_norm <- normalize_precinct(precincts[[precinct_id_col]])

projected_crs <- 3086
precincts <- st_transform(precincts, crs = projected_crs)

# --------------------------------------------------------------
# COUNTY — determined SPATIALLY (no COUNTY column in this shapefile)
# --------------------------------------------------------------
# Find which county boundary each precinct's centroid falls inside,
# using the same 4 counties from the Census pull below.

county_boundaries <- counties(state = "FL", cb = TRUE, year = 2020) %>%
  filter(NAME %in% c("Broward", "Palm Beach", "Hendry", "Collier")) %>%
  st_transform(projected_crs)

precinct_centroids <- st_centroid(precincts)

county_join <- st_join(
  precinct_centroids,
  county_boundaries["NAME"],
  join = st_within
)

precincts$COUNTY <- county_join$NAME

cat("\nCounty assignment check (NA = centroid didn't fall inside any of the 4 counties):\n")
print(table(precincts$COUNTY, useNA = "always"))

# --------------------------------------------------------------
# COUNTY CODE (matches the county code used in the live JSON URL:
# CLL = Collier, HEN = Hendry, PAL = Palm Beach)
# --------------------------------------------------------------
# Add more rows here if you add more counties/URLs later.

county_code_map <- c(
  "Collier"    = "CLL",
  "Hendry"     = "HEN",
  "Palm Beach" = "PAL"
  # "Broward"  = "BRW"   # <- add the real code here if/when you add a Broward feed
)

precincts$county_code <- county_code_map[precincts$COUNTY]

cat("\nCounty code assignment check (should have no NA except real edge cases):\n")
print(table(precincts$county_code, useNA = "always"))


# ==============================================================
# 2. PULL 2020 CENSUS BLOCK-LEVEL VAP DATA
# ==============================================================

vap_vars <- c(
  VAPTotal = "P4_001N",
  VAPHisp  = "P4_002N",
  VAPWhite = "P4_005N",
  VAPBlack = "P4_006N",
  VAPNat   = "P4_007N",
  VAPAsian = "P4_008N"
)

counties_list <- c("Broward", "Palm Beach", "Hendry", "Collier")

blocks <- get_decennial(
  geography = "block",
  variables = vap_vars,
  state = "FL",
  county = counties_list,
  year = 2020,
  sumfile = "pl",
  geometry = TRUE,
  output = "wide"
)

blocks <- st_transform(blocks, crs = projected_crs)

cat("\nBlocks pulled:", nrow(blocks), "\n")


# ==============================================================
# 3. ASSIGN BLOCKS TO PRECINCTS AND AGGREGATE DEMOGRAPHICS
# ==============================================================

block_centroids <- st_centroid(blocks)

block_to_precinct <- st_join(
  block_centroids,
  precincts[, precinct_id_col],
  join = st_within
)

unassigned <- sum(is.na(block_to_precinct[[precinct_id_col]]))
cat("Blocks with no matching precinct:", unassigned, "\n")

precinct_demo <- block_to_precinct %>%
  st_drop_geometry() %>%
  filter(!is.na(.data[[precinct_id_col]])) %>%
  group_by(.data[[precinct_id_col]]) %>%
  summarise(
    VAPTotal = sum(VAPTotal, na.rm = TRUE),
    VAPHisp  = sum(VAPHisp,  na.rm = TRUE),
    VAPWhite = sum(VAPWhite, na.rm = TRUE),
    VAPBlack = sum(VAPBlack, na.rm = TRUE),
    VAPNat   = sum(VAPNat,   na.rm = TRUE),
    VAPAsian = sum(VAPAsian, na.rm = TRUE),
    .groups = "drop"
  )

precincts <- precincts %>%
  left_join(precinct_demo, by = precinct_id_col) %>%
  mutate(
    white_pct = VAPWhite / VAPTotal * 100,
    hisp_pct  = VAPHisp  / VAPTotal * 100,
    black_pct = VAPBlack / VAPTotal * 100,
    asian_pct = VAPAsian / VAPTotal * 100,
    nat_pct   = VAPNat   / VAPTotal * 100
  )

race_pct_cols <- c("white_pct", "hisp_pct", "black_pct", "asian_pct", "nat_pct")
race_labels   <- c("White", "Hispanic", "Black", "Asian", "Native American")

race_matrix <- st_drop_geometry(precincts)[, race_pct_cols]

precincts$plurality_group <- apply(race_matrix, 1, function(row) {
  if (all(is.na(row))) return(NA_character_)
  race_labels[which.max(row)]
})


# ==============================================================
# 4. LOAD 2020 ELECTION SHAPEFILE + RESULTS
# ==============================================================

shp_2020_path <- file.choose()
results_2020 <- st_read(shp_2020_path, quiet = FALSE)
results_2020 <- st_zm(results_2020, drop = TRUE, what = "ZM")

dem_2020_col      <- "G20PREDBID"
rep_2020_col      <- "G20PRERTRU"
precinct_2020_col <- "PRECINCT"

g20_cols <- names(results_2020)[grepl("^G20", names(results_2020))]
if (length(g20_cols) == 0) stop("No G20 election vote columns found.")

results_2020 <- results_2020 %>%
  mutate(across(
    all_of(g20_cols),
    ~ suppressWarnings(as.numeric(gsub(",", "", as.character(.x))))
  ))

results_2020$Total_2020 <- rowSums(
  st_drop_geometry(results_2020)[, g20_cols, drop = FALSE],
  na.rm = TRUE
)

results_2020 <- results_2020 %>%
  mutate(
    dem_pct_2020 = ifelse(Total_2020 > 0, .data[[dem_2020_col]] / Total_2020 * 100, NA_real_),
    rep_pct_2020 = ifelse(Total_2020 > 0, .data[[rep_2020_col]] / Total_2020 * 100, NA_real_),
    precinct_norm = normalize_precinct(.data[[precinct_2020_col]])
  )

results_2020 <- st_transform(results_2020, crs = 4326)


# ==============================================================
# 5. LOAD 2024 ELECTION SHAPEFILE + RESULTS
# ==============================================================

shp_2024_path <- file.choose()
results_2024 <- st_read(shp_2024_path, quiet = FALSE)
results_2024 <- st_zm(results_2024, drop = TRUE, what = "ZM")

dem_2024_col      <- "G24PREDHAR"
rep_2024_col      <- "G24PRERTRU"
precinct_2024_col <- "PREC_ID"

g24_cols <- names(results_2024)[grepl("^G24", names(results_2024))]
if (length(g24_cols) == 0) stop("No G24 election vote columns found.")

results_2024 <- results_2024 %>%
  mutate(across(
    all_of(g24_cols),
    ~ suppressWarnings(as.numeric(gsub(",", "", as.character(.x))))
  ))

results_2024$Total_2024 <- rowSums(
  st_drop_geometry(results_2024)[, g24_cols, drop = FALSE],
  na.rm = TRUE
)

results_2024 <- results_2024 %>%
  mutate(
    dem_pct_2024 = ifelse(Total_2024 > 0, .data[[dem_2024_col]] / Total_2024 * 100, NA_real_),
    rep_pct_2024 = ifelse(Total_2024 > 0, .data[[rep_2024_col]] / Total_2024 * 100, NA_real_),
    precinct_norm = normalize_precinct(.data[[precinct_2024_col]])
  )

results_2024 <- st_transform(results_2024, crs = 4326)


# ==============================================================
# 6. EXPORT GEOJSON FOR THE WEB MAP
# ==============================================================

precincts_map <- st_transform(precincts, crs = 4326) %>%
  select(
    PRECINCT_ID, precinct_norm, COUNTY, county_code,
    white_pct, hisp_pct, black_pct, asian_pct, nat_pct,
    plurality_group
  )

results_2020_out <- results_2020 %>%
  select(
    !!precinct_2020_col, precinct_norm,
    dem_pct_2020, rep_pct_2020, Total_2020
  )

results_2024_out <- results_2024 %>%
  select(
    !!precinct_2024_col, precinct_norm,
    dem_pct_2024, rep_pct_2024, Total_2024
  )

unlink(file.path(out_dir, "demographics.geojson"))
unlink(file.path(out_dir, "election_2020.geojson"))
unlink(file.path(out_dir, "election_2024.geojson"))

st_write(precincts_map,     file.path(out_dir, "demographics.geojson"),  driver = "GeoJSON")
st_write(results_2020_out,  file.path(out_dir, "election_2020.geojson"), driver = "GeoJSON")
st_write(results_2024_out,  file.path(out_dir, "election_2024.geojson"), driver = "GeoJSON")

cat("\nDone. Wrote demographics.geojson, election_2020.geojson, election_2024.geojson to:\n")
cat(normalizePath(out_dir), "\n")
cat("\nCopy these three files into precinct-map-live/data/ and open index.html.\n")

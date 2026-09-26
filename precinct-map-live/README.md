# Live precinct map — setup & deployment

## What changed vs. your original R script
- Demographics, 2020 results, and 2024 results are still built the same way in R —
  but now exported once as static GeoJSON instead of an R/Leaflet htmlwidget.
- The old xlsx-based turnout section is gone. The "Early/Mail Voting" layer is now
  built live, in the browser, straight from your 3 county JSON feeds — so it's
  current every time the page loads, with no manual updating.
- Your shapefile has no `COUNTY` column, so county is now determined
  **spatially**: each precinct's centroid is checked against the actual county
  boundaries (pulled via `tigris`) to figure out which county it's in. This
  replaced the earlier version that expected a `COUNTY` column directly.

## One-time setup
1. Run `export_geojson.R` in R (same `file.choose()` prompts as before, for your
   precinct shapefile, 2020 results shapefile, and 2024 results shapefile).
2. Watch the console output for two tables it prints — `County assignment
   check` and `County code assignment check`. Every precinct should land in
   one of Broward / Palm Beach / Hendry / Collier, and every code should be
   CLL / HEN / PAL (Broward has no live feed yet, so those will just show as
   `NA` for county_code — that's expected until you add one).
3. It writes `demographics.geojson`, `election_2020.geojson`, and
   `election_2024.geojson` into `data/`, so the folder looks like:

```
precinct-map-live/
├── index.html
├── export_geojson.R
├── README.md
└── data/
    ├── demographics.geojson
    ├── election_2020.geojson
    └── election_2024.geojson
```

## Running it locally
Opening `index.html` by double-clicking it will NOT work — browsers block
`fetch()` on local files for security. Instead, run a quick local server:

1. Open Terminal (Mac) or Command Prompt (Windows)
2. `cd` into the `precinct-map-live` folder (type `cd ` with a trailing space,
   then drag the folder into the terminal window, then press Enter)
3. Run:
   ```
   python3 -m http.server
   ```
   (Windows: try `python -m http.server` if `python3` doesn't work)
4. Open `http://localhost:8000` in your browser

## Checking the turnout match worked
Open the browser console (right-click → Inspect → Console) after the page
loads. You'll see a line like:

```
Turnout match summary — matched: 214, no county_code: 0, county ok but no turnout row: 3
```

- **matched** = precincts that successfully got live turnout numbers
- **no county_code** = precincts where the spatial county join failed (check
  the R console output tables from setup step 2)
- **county ok but no turnout row** = precinct's county matched fine, but that
  specific precinct ID wasn't in the live feed for that county (could be a
  precinct-ID mismatch, or the county's feed just hasn't reported anything for
  it yet)

## Deploying so it's a real, shareable URL
Any static host works since there's no backend — pick one:

**GitHub Pages** (free, simple)
1. Create a repo, push this whole folder (`index.html` + `data/`).
2. Repo Settings → Pages → set source to your main branch.
3. Your map is live at `https://<username>.github.io/<repo>/`.

**Netlify / Cloudflare Pages** (free, drag-and-drop)
1. Drag the `precinct-map-live` folder onto Netlify's dashboard (or connect the
   GitHub repo for auto-deploy on every push).
2. You get a live URL immediately.

## Re-running when things change
- **Turnout**: nothing to do — it updates on its own every time someone loads
  the page, straight from the county feeds.
- **Demographics / 2020 / 2024 results**: only if your underlying shapefiles
  change. Re-run `export_geojson.R`, replace the 3 files in `data/`, redeploy.

## Adding more counties later
In `index.html`, add a row to `TURNOUT_SOURCES` with the county's 3-letter code
(matching the code in its live JSON URL) and its feed URL. In
`export_geojson.R`, add the matching row to `county_code_map`, and add the
county's name to the `filter(NAME %in% c(...))` list in both the county
boundary pull and the Census `counties_list`.

## Notes / things worth double-checking
- The live JSON's precinct keys (e.g. `"317.0"`) are normalized the same way
  your original `normalize_precinct()` did (trim, drop trailing `.0`), so they
  should match `PRECINCT_ID` cleanly — but spot-check a few precincts after
  first deploy, especially Collier's `"Precinct 101"` → `"101"` conversion.
- The demographic category colors are a fixed palette I assigned (not pulled
  from R's `colorFactor`, which orders colors alphabetically by category name
  under the hood) — visually equivalent, just confirm the colors look right
  to you: White `#FF7F00`, Hispanic `#4DAF4A`, Black `#377EB8`, Asian `#E41A1C`,
  Native American `#984EA3`.
- The turnout color scale is dynamically stretched between whatever min/max
  `% returned` shows up live each time the page loads — so the color a given
  precinct shows may shift slightly over the election as the range changes.
- If a county's live feed is briefly down, that layer just falls back to gray
  for those precincts rather than breaking the whole map.

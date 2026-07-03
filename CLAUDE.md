# internet.rip — a "status page of the internet"

A fullscreen dark dashboard showing the health of core internet infrastructure on
a world map: DNS root servers, TLD name servers, service statuses, site
reachability, country-level outages, plus submarine cables / IXPs / landing
points. Aesthetic: terminal / mono (Berkeley Mono), designed to look good as a
wall dashboard.

**Stack:** Ruby 4.0.1, Rails 8.1, Puma, propshaft, importmap, sqlite3. No
Turbo/Stimulus. Cache is `:memory_store` in every env (see gotchas). See
`README.md` for the per-source data table and `rake data:update`.

## Architecture

**Monitors** (`app/monitors/`) — one per data source, all subclass `BaseMonitor`:
- Implement `#fetch` (returns any serializable data); set `self.title` /
  `self.interval` (seconds until a snapshot is considered stale).
- `BaseMonitor` handles caching + **stale-while-revalidate**: `snapshot` reads
  the cached result; `refresh_if_stale` spawns a background thread to refetch
  when stale. **The request path never blocks on the network** — that's the core
  invariant. First paint may show "loading" placeholders; the browser poll fills
  them in seconds later.
- Helpers on the base: `get_json`, `http_get`, `probe` (HTTP), `dns_probe`,
  `in_parallel` (thread-fan-out for per-item fetches).

Current monitors: `RootServersMonitor`, `TldMonitor`, `ServiceStatusMonitor`,
`PublicSitesMonitor`, `OutagesMonitor`.

**Static geo** (`app/models/infrastructure.rb`) — cables / landing points / IXPs
parsed once from `data/*` GeoJSON, memoized. Refresh via `rake data:update`.

**Controller** (`InternetController`): `index` renders the full page (heavy static
base map); `live` renders `_live` partial only. `before_action :load_monitors`
reads all snapshots (referencing each constant so it registers) then calls
`BaseMonitor.refresh_all_if_stale`.

**Views:**
- `index.html.erb` — stacked SVG layers (all viewBox `0 0 2000 857`): grid,
  countries (`InternetHelper::SVG_MAP`), cables, infra dots, then `#live`.
- `_live.html.erb` — everything dynamic: status banner, panels, and an injected
  `<style>` that highlights countries. Polled every ~12s and swapped into `#live`
  (base map is untouched). Uses `concat` for map overlays.
- `layouts/application.html.erb` — has the inline JS poller + a 1s clock tick.

**Helper** (`app/helpers/internet_helper.rb`): `robinson_svg(lat,lng)` (Robinson
projection, hand-tuned for this map's 2000×857 viewBox), `sparkline` (inline SVG,
**baselined at 0** so stable series read flat), `cables_layer` (with antimeridian
splitting), `infra_layer`.

## Conventions & gotchas (non-obvious)

- **`BaseMonitor`, not `Monitor`** — Ruby stdlib defines a top-level `::Monitor`
  (thread mutex). Zeitwerk sees it already defined and won't load a file named
  `Monitor`, silently breaking everything. Never name it `Monitor`.
- **Cache must be a real store.** Monitors rely on `Rails.cache`; dev/test default
  to `:null_store`, so `config.cache_store = :memory_store` is set in
  `application.rb` **and** re-asserted in `config/environments/{development,test}.rb`.
- **Country highlighting** = inject `<style>.XX { fill: … }` in `_live` (country
  `<path>`s are classed by ISO-3166 alpha-2). Always sanitise codes to
  `/\A[A-Z]{2}\z/` before building selectors. Sources: IODA outages + degraded
  ccTLDs. ccTLD→country is usually `upcase`, with exceptions (`uk`→GB, and the IDN
  ccTLDs in `TldMonitor::COUNTRY`).
- **DNSMON is the root/TLD source of truth.** Don't hand-roll DNS availability —
  read `https://dnsmon.ripe.net/api/servers?group=<zone>` (aggregated
  replies/queries + rtt percentiles). Groups: `/api/groups`. Deep-link a zone via
  path: `https://dnsmon.ripe.net/<zone>`. Zone labels already carry the Unicode
  form of IDN punycode (`"бел. (xn--90ais.)"`).
- **`TldMonitor` rotates** — DNSMON serves only the full ~200 kB series per zone
  (no summary mode), and there are ~70 zones. So it re-checks only `BATCH` stalest
  zones per tick and accumulates. Keep the request rate low; don't sweep all zones
  at once.
- **Tests** (`test/monitors`, `test/integration`) seed `Rails.cache` directly to
  stay hermetic (no network). To block a cold-cache refresh in a test, pre-take
  each monitor's `lock_key`. Minitest here has **no `minitest/mock`** — don't
  `require` it.
- **Screenshots via the browser tool fail** — the live SVG + timers never reach
  "document idle", so the screenshot/get_page_text tools time out. Verify
  rendering by inspecting the DOM with `javascript_tool` instead.

## Running / verifying

- Run: `bin/rails s` (or `PIDFILE=… bin/rails s -p <port>` for a scratch port).
  Foreground `sleep` is blocked in this env — poll with `curl --retry`.
- Health: `/up`. Data endpoint: `/live`.
- Tests: `bin/rails test`.
- Refresh map data: `rake data:update` (or `data:cables` / `data:landing_points` /
  `data:ixps`).

## Roadmap (from the owner's project notes)

RIPE Atlas, IHR alarm aggregation, per-cable fault status, public-DNS resolver
health. **Terrestrial cables: intentionally skipped** — no clean open source
(only Infrapedia MVT tiles, sunsetted) and too visually dense for this view.

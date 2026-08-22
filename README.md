# (×\_×) Internet.RIP (or RIPinter.net)

The purpose of this this small Rails application is to provider a simple & high-level status page for the internet.

## Run locally

```sh
bundle install
bin/rails s
```

## Data & Monitors

Live data is collected by small "monitors" in `app/monitors/`, each a subclass of
`BaseMonitor` (named `Base*` because Ruby's stdlib already owns the `Monitor`
constant). A monitor implements `#fetch` and declares an `interval`; the base
class handles everything else:

- **Caching** — each result is stored in `Rails.cache` (an in-process
  `:memory_store`) with a timestamp.
- **Stale-while-revalidate** — the controller reads whatever is cached and, if a
  snapshot is stale, kicks off a background thread to refresh it. Rendering
  **never blocks on the network**, so the page always loads instantly.

Current sources (all keyless except `PublicResolversMonitor`/`UpdownMonitor`, see below):

| Monitor | Source |
| --- | --- |
| `RootServersMonitor`   | Availability + median RTT of the 13 root servers (A–M) taken directly from [RIPE DNSMON](https://dnsmon.ripe.net)'s API (`/api/servers?group=root`), which aggregates query/reply counts and RTT percentiles across its global probe fleet — no reproduction of their methodology on our side. Each row shows a latency (rtt50) sparkline and links to the authoritative measurement. Not plotted on the map — root servers are anycast. |
| `TldMonitor`           | Availability of the ~70 ccTLD/gTLD zones RIPE DNSMON tracks (`/api/servers?group=<tld>`). DNSMON only serves the full time series per zone (~200 kB, no summary mode), so this monitor **rotates** — re-checking only the few stalest zones each tick and accumulating results — keeping the request rate low (a handful/min, only while the dashboard is open) and refreshing each zone ~every 30 min. |
| `ServiceStatusMonitor` | Atlassian Statuspage `/api/v2/status.json` for major services |
| `PublicSitesMonitor`   | HTTPS reachability + latency of landmark sites |
| `OutagesMonitor`       | [IODA](https://ioda.inetintel.cc.gatech.edu) country-level connectivity outages (BGP + active probing + telescope). Affected countries are highlighted on the map by their ISO-2 `<path>` class. |
| `GripMonitor`          | [GRIP](https://grip.inetintel.cc.gatech.edu) (Georgia Tech) BGP routing anomalies — hijacks, sub-prefix hijacks, route leaks — inferred from RPKI/IRR/AS-relationship heuristics. The background rate of low-grade flags is huge, so this is a recent-events feed at a high suspicion floor, not a health signal; it does not feed the overall status banner. |
| `PublicResolversMonitor` | Latency + 30-day uptime of well-known public recursive DNS resolvers (Google, Cloudflare, Quad9, OpenDNS) — the servers people's devices actually query, unlike the authoritative root/TLD servers above. Sourced from [PerfOps/DNSPerf](https://www.dnsperf.com/#!dns-resolvers), which tests every provider every minute from 200+ locations worldwide; probing them directly from just this one server was tried first and dropped, since a resolver regionally blocked or rerouted (e.g. OpenDNS in France) reads as "down" from a single vantage point even when it's fine globally. **Needs an API key** — see Credentials below. |
| `UpdownMonitor`        | Global heatmap of currently-failing [updown.io](https://updown.io) checks (blurred red dots on the map, sized by count), plus a panel of the worst-hit ISPs by 24h failure rate. Backed by a small protected endpoint on updown's own codebase (`InternetRipController`, deliberately kept out of its public Grape API) that pre-aggregates and rounds geo data server-side, excludes checks down for over a week as chronic/abandoned rather than a real-time outage, and drops ISPs below a minimum sample size — so no individual customer's check is ever exposed. Not a health signal for the internet at large — some fraction of any large customer base is always down for reasons unrelated to broader connectivity — so like `GripMonitor` it doesn't feed the overall status banner. **Needs an API key** — see Credentials below. |

Static map geography is loaded once via `app/models/infrastructure.rb` from local
GeoJSON files, refreshable with **`rake data:update`** (see `lib/tasks/data.rake`):

| Layer | Source | File |
| --- | --- | --- |
| Submarine cable routes    | [TeleGeography](https://www.submarinecablemap.com) | `data/submarinecables/cable-geo.json` |
| Submarine cable landings  | TeleGeography | `data/submarinecables/landing-point-geo.json` |
| Internet Exchange Points  | [PeeringDB](https://www.peeringdb.com) (geocoded via facilities) | `data/peeringdb/ixps.json` |

No live per-cable fault status is published, so cables are routes only. Refresh
individually with `rake data:cables`, `rake data:landing_points`, or
`rake data:ixps`.

The browser polls `/live` every ~12s to swap in fresh data without re-rendering
the (heavy, static) base map. To add a source, drop a new `*Monitor` in
`app/monitors/` and render its `snapshot` in `app/views/internet/_live.html.erb`.

Ideas still on the roadmap (see project notes): RIPE Atlas and IHR alarm
aggregation. Per-cable fault status is intentionally skipped (no clean open
data source since Infrapedia's MVT tiles sunsetted).

### Credentials

`PublicResolversMonitor` needs a [PerfOps](https://perfops.net) API key (free
tier works, but is capped at one resolver per request and daily — not
hourly/minute — granularity, which is why that monitor fans out one request
per resolver and refreshes only hourly). Set it with:

```sh
bin/rails credentials:edit
```

```yaml
perfops:
  api_key: your_api_key_here
```

Without it, that one monitor just shows an error state; every other monitor
is unaffected.

`UpdownMonitor` needs a shared-secret token matching the one configured on
the updown.io side (`internet_rip.token` in its own credentials):

```yaml
updown:
  token: the_shared_secret
```

## World Map

The background SVG world map comes from https://simplemaps.com/resources/svg-world, on which we apply some fixes for inconsistencies in the `data/simplemaps/process_map.rb` script. So if the map needs updating, we should update the file in `data/simplemaps` and then run the script again to generate the processed version in `lib/assets/images`.

The Robinson projection has been fine-tuned for this map (which is unfortunately cropped on the sides), so in case of updates, it would be a good idea to verify the coordinates grid alignement again.
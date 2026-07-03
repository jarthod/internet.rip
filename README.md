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

Current sources (all keyless):

| Monitor | Source |
| --- | --- |
| `RootServersMonitor`   | Availability + median RTT of the 13 root servers (A–M) taken directly from [RIPE DNSMON](https://dnsmon.ripe.net)'s API (`/api/servers?group=root`), which aggregates query/reply counts and RTT percentiles across its global probe fleet — no reproduction of their methodology on our side. Each row shows a latency (rtt50) sparkline and links to the authoritative measurement. Not plotted on the map — root servers are anycast. |
| `TldMonitor`           | Availability of the ~70 ccTLD/gTLD zones RIPE DNSMON tracks (`/api/servers?group=<tld>`). DNSMON only serves the full time series per zone (~200 kB, no summary mode), so this monitor **rotates** — re-checking only the few stalest zones each tick and accumulating results — keeping the request rate low (a handful/min, only while the dashboard is open) and refreshing each zone ~every 30 min. |
| `ServiceStatusMonitor` | Atlassian Statuspage `/api/v2/status.json` for major services |
| `PublicSitesMonitor`   | HTTPS reachability + latency of landmark sites |
| `OutagesMonitor`       | [IODA](https://ioda.inetintel.cc.gatech.edu) country-level connectivity outages (BGP + active probing + telescope). Affected countries are highlighted on the map by their ISO-2 `<path>` class. |

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

Ideas still on the roadmap (see project notes): RIPE Atlas, IHR alarm
aggregation, per-cable fault status, and public-DNS resolver health.

## World Map

The background SVG world map comes from https://simplemaps.com/resources/svg-world, on which we apply some fixes for inconsistencies in the `data/simplemaps/process_map.rb` script. So if the map needs updating, we should update the file in `data/simplemaps` and then run the script again to generate the processed version in `lib/assets/images`.

The Robinson projection has been fine-tuned for this map (which is unfortunately cropped on the sides), so in case of updates, it would be a good idea to verify the coordinates grid alignement again.
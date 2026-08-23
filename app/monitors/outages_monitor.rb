# Global connectivity/routing outages from IODA (Internet Outage Detection and
# Analysis, Georgia Tech). IODA fuses BGP, active probing and network-telescope
# signals to detect country/region/ASN level internet outages.
#
# We ask for country-level outages over the last 24h; the returned ISO-3166
# alpha-2 codes line up with the map's country <path> classes, so affected
# countries can be highlighted directly on the map.
class OutagesMonitor < BaseMonitor
  self.title = "Connectivity Outages"
  self.interval = 300

  API = "https://api.ioda.inetintel.cc.gatech.edu/v2/outages/summary".freeze
  WINDOW = 24 * 3600
  # Above this IODA "overall" score we consider the outage severe (red vs amber).
  SEVERE_SCORE = 100_000

  # IODA's per-country score breaks down by contributing datasource (keys like
  # "bgp.median", "ping-slash24.median" alongside "overall"). Surface the
  # dominant one as a human-readable "why is this flagged" reason.
  DATASOURCE_LABEL = {
    "bgp"          => "BGP routing withdrawals",
    "ping-slash24" => "active probing unreachability",
    "gtr"          => "search traffic anomaly",
    "merit-nt"     => "darknet traffic anomaly",
  }.freeze

  def fetch
    now = Time.now.to_i
    url = "#{API}?from=#{now - WINDOW}&until=#{now}&entityType=country&orderBy=score&limit=25"
    json = get_json(url, timeout: 10)

    countries = Array(json["data"]).filter_map do |e|
      code = e.dig("entity", "code")
      next unless code

      scores = e["scores"] || {}
      score = scores["overall"].to_f
      driver = scores.except("overall").max_by { |_, v| v.to_f }
      datasource = driver && driver[0].sub(/\.median\z/, "")

      {
        code: code,
        # IODA's own entity name is inconsistently formatted ("Cote D
        # Ivoire", "Korea, Republic of"); ISO3166's common_name reads like a
        # normal English name ("Côte d'Ivoire", "South Korea").
        name: ISO3166::Country.new(code)&.common_name || e.dig("entity", "name"),
        score: score,
        # IODA's raw score has no fixed ceiling of its own; expressed as a
        # percentage of the "severe" cutoff instead (capped at 100) it reads
        # as a rough severity gauge instead of an opaque number.
        pct: [100.0 * score / SEVERE_SCORE, 100.0].min.round,
        events: e["event_cnt"].to_i,
        severe: score >= SEVERE_SCORE,
        # IODA doesn't always break the score down by datasource (no driver
        # clearly dominant, or a key outside DATASOURCE_LABEL) — fall back to
        # a generic reason rather than leaving the row with a bare percentage
        # and no explanation at all.
        reason: DATASOURCE_LABEL[datasource] || "elevated outage signal",
        datasource: datasource,
        url: "https://ioda.inetintel.cc.gatech.edu/country/#{code}",
      }
    end.sort_by { -_1[:score] }

    { countries: countries, count: countries.size }
  end
end

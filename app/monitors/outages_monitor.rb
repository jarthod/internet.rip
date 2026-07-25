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

  SPARK_COUNT  = 8 # matches the view's `.first(8)` — don't fetch spark for rows never shown
  SPARK_POINTS = 24
  SIGNALS_API  = "https://api.ioda.inetintel.cc.gatech.edu/v2/signals/raw/country/%s".freeze

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
        name: e.dig("entity", "name"),
        score: score,
        events: e["event_cnt"].to_i,
        severe: score >= SEVERE_SCORE,
        reason: DATASOURCE_LABEL[datasource],
        datasource: datasource,
        url: "https://ioda.inetintel.cc.gatech.edu/country/#{code}",
      }
    end.sort_by { -_1[:score] }

    top = countries.first(SPARK_COUNT)
    sparks = in_parallel(top.select { _1[:datasource] }) { |c| [c[:code], fetch_spark(c[:code], c[:datasource])] }.to_h
    top.each { |c| c[:spark] = sparks[c[:code]] }

    { countries: countries, count: countries.size }
  end

  private

  def fetch_spark(code, datasource)
    now = Time.now.to_i
    url = "#{SIGNALS_API % code}?from=#{now - WINDOW}&until=#{now}&datasource=#{datasource}"
    json = get_json(url, timeout: 8)
    values = json.dig("data", 0, 0, "values")
    values && downsample(values.compact, SPARK_POINTS)
  rescue
    nil
  end
end

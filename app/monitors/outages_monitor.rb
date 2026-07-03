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

  def fetch
    now = Time.now.to_i
    url = "#{API}?from=#{now - WINDOW}&until=#{now}&entityType=country&orderBy=score&limit=25"
    json = get_json(url, timeout: 10)

    countries = Array(json["data"]).filter_map do |e|
      code = e.dig("entity", "code")
      next unless code

      score = e.dig("scores", "overall").to_f
      {
        code: code,
        name: e.dig("entity", "name"),
        score: score,
        events: e["event_cnt"].to_i,
        severe: score >= SEVERE_SCORE,
        url: "https://ioda.inetintel.cc.gatech.edu/country/#{code}",
      }
    end.sort_by { -_1[:score] }

    { countries: countries, count: countries.size }
  end
end

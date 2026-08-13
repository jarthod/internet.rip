# BGP routing anomalies (route hijacks, sub-prefix hijacks, and leaks) from
# GRIP (Global Routing Intelligence Platform, Georgia Tech). GRIP replays the
# global BGP feed through inference heuristics (RPKI validity, IRR records, AS
# relationships) and assigns each detected anomaly a suspicion level.
#
# The background rate of low-grade "suspicious" events (mostly benign
# misconfigurations flagged by RPKI/IRR mismatches, not real attacks) is huge
# — tens of thousands a day even at a high suspicion floor — so this is a
# recent-events feed to skim, not a health signal. It deliberately does NOT
# feed the dashboard's overall status banner the way the other monitors do.
class GripMonitor < BaseMonitor
  self.title = "Routing Anomalies"
  self.interval = 300

  API = "https://api.grip.inetintel.cc.gatech.edu/dev/json/events".freeze
  WEB = "https://grip.inetintel.cc.gatech.edu/v1/events".freeze
  WINDOW = 24 * 3600
  MIN_SUSPICION = 80
  LIMIT = 15

  EVENT_LABEL = {
    "moas"    => "possible hijack",
    "submoas" => "possible sub-prefix hijack",
    "defcon"  => "possible route leak",
    "edges"   => "new AS adjacency",
  }.freeze

  def fetch
    ts_start = (Time.now.to_i - WINDOW)
    url = "#{API}?ts_start=#{Time.at(ts_start).utc.strftime('%Y-%m-%dT%H:%M:%S')}" \
          "&min_susp=#{MIN_SUSPICION}&length=#{LIMIT}"
    json = get_json(url, timeout: 10)

    # Ongoing events (finished_at nil — still actively being announced) surface
    # above ones that already resolved, newest first within each group.
    events = Array(json["data"]).filter_map { |e| build_event(e) }
                                 .sort_by { |e| [e[:finished_at] ? 1 : 0, -e[:time].to_i] }

    { events: events }
  end

  private

  def build_event(e)
    inference = e.dig("summary", "inference_result", "primary_inference")
    return nil unless inference

    finished_ts = e["finished_ts"]

    {
      id: e["id"],
      label: EVENT_LABEL[e["event_type"]] || e["event_type"],
      time: Time.at(e["view_ts"].to_i),
      finished_at: finished_ts && Time.at(finished_ts.to_i),
      explanation: inference["explanation"],
      suspicion: inference["suspicion_level"].to_i,
      # The suspect prefix(es): what you'd check your own route/destination
      # against. `moas` events carry one prefix; `submoas` carry both the
      # narrower sub-prefix and the wider super-prefix it was carved from.
      prefixes: Array(e.dig("summary", "prefixes")),
      countries: event_countries(e),
      url: "#{WEB}/#{e['event_type']}/#{e['id']}",
    }
  end

  # Countries of the ASes involved, via GRIP's bundled ASRank org data.
  def event_countries(e)
    Array(e.dig("summary", "ases")).filter_map { |asn|
      e.dig("asinfo", asn, "asrank", "organization", "country", "iso")
    }.select { _1.match?(/\A[A-Z]{2}\z/) }.uniq
  end
end

# Global connectivity/routing outages from IODA (Internet Outage Detection and
# Analysis, Georgia Tech). IODA fuses BGP, active probing and network-telescope
# signals to detect country/region/ASN level internet outages.
#
# We ask for country-level outages over the last 24h; the returned ISO-3166
# alpha-2 codes line up with the map's country <path> classes, so affected
# countries can be highlighted directly on the map.
#
# IODA's own ranking number ("overall" score) is an accumulated alert-area: it
# multiplies together the firing signals and integrates over the event, so it
# conflates depth with duration and its per-/24 median detector is jumpy on
# small countries (Cabo Verde, ~120 routed /24s, throws a stream of tiny events
# that add up to a scary-looking total while the raw signal never dips below
# ~95% of normal). So we don't trust the score for severity — we pull a week of
# the raw driver signal for each flagged country and measure how far it sits
# *right now* below its weekly median. Countries whose signal is within MIN_DROP
# of normal are treated as contradicting IODA's flag and dropped.
class OutagesMonitor < BaseMonitor
  self.title = "Country Connectivity Outages"
  self.interval = 300

  API = "https://api.ioda.inetintel.cc.gatech.edu/v2/outages/summary".freeze
  SIGNALS_API = "https://api.ioda.inetintel.cc.gatech.edu/v2/signals/raw/country/%s".freeze
  WINDOW = 24 * 3600
  # How far back to pull the raw signal when establishing "normal". Needs to be
  # long enough that an outage that's been running for most of a day — or a
  # multi-day one — still has healthy samples to be measured against, but not so
  # long that a country IODA has since renormalised drags its own baseline down.
  BASELINE_WINDOW = 7 * 86400
  # IODA defaults to extending the query window back 14 days to keep a
  # still-running outage visible; that dumps a slow multi-day anomaly's whole
  # accumulated score into a row that looks current. We want the last 24h only.
  EXTEND_WINDOW = 0
  # Verify at most this many of IODA's flagged countries against the raw signal
  # (one extra HTTP call each, fanned out). The panel only shows 8.
  VERIFY_COUNT = 12
  # Fraction below baseline under which we treat the "outage" as measurement
  # noise and drop the row; and at/above which we call it a severe outage.
  # The floor is deliberately low — IODA already vouched for the country, this
  # is just filtering out the ones whose raw signal flatly contradicts it.
  MIN_DROP = 0.05
  SEVERE_DROP = 0.5

  # IODA's per-country score breaks down by contributing datasource (keys like
  # "bgp.median", "ping-slash24.median", "gtr.sarima" alongside "overall").
  # We list the signals that fired as a plain-English "why is this flagged".
  DATASOURCE_LABEL = {
    "bgp"          => "BGP routing",
    "ping-slash24" => "active probing",
    "gtr"          => "search traffic",
    "merit-nt"     => "network telescope",
  }.freeze
  # ...but only these two actually mean "hosts here are unreachable". A dip in
  # search traffic or network-telescope packets alone is a soft/corroborating
  # signal (and both are noisy on small populations) — not something to put on
  # a connectivity board on its own. Severity is measured off one of these.
  CONNECTIVITY_SIGNALS = %w[ping-slash24 bgp].freeze

  def fetch
    now = Time.now.to_i
    url = "#{API}?from=#{now - WINDOW}&until=#{now}&entityType=country&orderBy=score" \
          "&limit=25&extendWindow=#{EXTEND_WINDOW}"
    json = get_json(url, timeout: 10)

    flagged = Array(json["data"]).filter_map do |e|
      code = e.dig("entity", "code")
      next unless code

      components = (e["scores"] || {}).except("overall")
      # Signals that fired, strongest first.
      signals = components.sort_by { |_, v| -v.to_f }.map { _1[0].sub(/\.\w+\z/, "") }.uniq
      # Drive severity off the strongest *connectivity* signal; skip countries
      # flagged only on search traffic / telescope noise.
      driver = signals.find { CONNECTIVITY_SIGNALS.include?(_1) }
      next unless driver

      {
        code: code,
        # IODA's own entity name is inconsistently formatted ("Cote D
        # Ivoire", "Korea, Republic of"); ISO3166's common_name reads like a
        # normal English name ("Côte d'Ivoire", "South Korea").
        name: ISO3166::Country.new(code)&.common_name || e.dig("entity", "name"),
        rank: (e.dig("scores", "overall")).to_f,
        events: e["event_cnt"].to_i,
        signals: signals,
        datasource: driver,
        url: "https://ioda.inetintel.cc.gatech.edu/country/#{code}",
      }
    end.sort_by { -_1[:rank] }

    verify = flagged.first(VERIFY_COUNT)
    drops = in_parallel(verify) { |c| [c[:code], current_drop(c[:code], c[:datasource])] }.to_h

    countries = verify.filter_map do |c|
      drop = drops[c[:code]]
      # Measured a solid signal and it's basically at normal → IODA's detector
      # is jumpy here, not a real outage. Drop the row.
      next if drop && drop < MIN_DROP

      labels = c[:signals].filter_map { DATASOURCE_LABEL[_1] }
      {
        code: c[:code],
        name: c[:name],
        # Percent below normal for the driver signal. When we couldn't measure
        # it (no datasource, fetch failed, too little data) fall back to a
        # modest amber so IODA's flag isn't silently hidden.
        pct: drop ? (drop * 100).round : 30,
        severe: drop ? drop >= SEVERE_DROP : false,
        events: c[:events],
        # Panel row shows just the driver signal (rows are narrow); the full
        # list of contributing signals goes in the row's title / map tooltip.
        reason: "#{DATASOURCE_LABEL[c[:datasource]]} down",
        reason_full: labels.size > 1 ? "#{labels.join(" + ")} down" : nil,
        datasource: c[:datasource],
        url: c[:url],
      }
    end.sort_by { -_1[:pct] }

    { countries: countries, count: countries.size }
  end

  private

  # Fraction (0.0..1.0) the country's current level for `datasource` sits below
  # its normal level, or nil if we couldn't get a usable series. Both
  # connectivity signals move the same way — fewer visible prefixes (bgp) or
  # fewer reachable /24s (ping-slash24) both mean "worse".
  #
  # "Normal" is the median over BASELINE_WINDOW (a week): the country's typical
  # level, so a still-running or days-old outage is still measured against
  # mostly-healthy samples rather than its own depressed recent average, while
  # a noisy signal doesn't manufacture a "drop" the way a near-peak percentile
  # would. (An outage that's run for >half the week pulls the median down with
  # it and under-reads — accepted; those are rare and score huge in IODA
  # anyway.) "Current" is the last couple of hours. A country IODA flags that
  # has genuinely sat flat all week reads ~0 and gets dropped — correct:
  # nothing changed.
  def current_drop(code, datasource)
    return nil unless datasource

    now = Time.now.to_i
    url = "#{SIGNALS_API % code}?from=#{now - BASELINE_WINDOW}&until=#{now}&datasource=#{datasource}"
    series = get_json(url, timeout: 8).dig("data", 0, 0)
    values = Array(series && series["values"]).compact
    return nil if values.size < 24

    baseline = values.sort[values.size / 2].to_f
    return nil if baseline <= 0

    # Last ~2h of samples (series step is 600s), min 3 points.
    recent = values.last([7200 / (series["step"].to_i.nonzero? || 600), 3].max)
    level = recent.sum / recent.size.to_f
    [(baseline - level) / baseline, 0.0].max
  rescue
    nil
  end
end

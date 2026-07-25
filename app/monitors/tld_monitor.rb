# Health of the ccTLD / gTLD name servers that RIPE DNSMON monitors (~70 zones:
# com, net, org, de, uk, fr, jp, ...), sourced from DNSMON's own aggregation.
#
# DNSMON only serves the *full* time series per zone (~200 kB, no summary mode),
# so pulling all 70 at once would be wasteful and unfriendly to their API.
# Instead this monitor ROTATES: on each refresh it re-checks only the few stalest
# zones and accumulates the results, so coverage builds up over ~30 min while the
# request rate stays low (a handful per minute, and only while someone is looking
# at the dashboard). Each zone is therefore refreshed roughly every half hour,
# which is plenty for something that changes as slowly as TLD DNS availability.
class TldMonitor < BaseMonitor
  self.title = "TLD Name Servers"
  self.interval = 90 # seconds between rotation ticks
  BATCH = 4           # zones re-checked per tick
  SPARK_POINTS = 48

  GROUPS = "https://dnsmon.ripe.net/api/groups".freeze
  SERVERS = "https://dnsmon.ripe.net/api/servers?group=%s".freeze

  # ccTLDs whose zone id isn't the ISO-3166 alpha-2 country code (incl. the IDN
  # ccTLDs DNSMON tracks). Used to highlight the country on the map.
  COUNTRY = {
    "uk" => "GB", "xn--90ais" => "BY", "xn--90a3ac" => "RS",
    "xn--mgberp4a5d4ar" => "SA", "xn--mgbaam7a8h" => "AE", "xn--j6w193g" => "HK",
  }.freeze

  def fetch
    zones = zone_ids
    known = (self.class.snapshot.data&.dig(:zones) || {}).slice(*zones)

    # Re-check the least-recently-checked zones first (unseen zones sort first).
    due = zones.min_by(BATCH) { |z| known.dig(z, :checked_at) || Time.at(0) }
    in_parallel(due) { |z| [z, summarize(z)] }.each { |z, s| known[z] = s if s }

    summaries = known.values
    problems = summaries.reject { _1[:status] == "ok" }.sort_by { _1[:avail] }
    { zones: known, total: zones.size, checked: summaries.size,
      ok: summaries.count { _1[:status] == "ok" }, problems: problems }
  end

  private

  def summarize(zone)
    json = get_json(SERVERS % zone, timeout: 12)
    servers = Array(json["servers"]).select { _1["ip_version"] == 4 }

    # Per name server, availability over the last 3 buckets (~30 min) so a single
    # noisy bucket doesn't flag an otherwise-healthy zone.
    avails = servers.filter_map do |s|
      recent = Array(s["results"]).reverse.first(3).select { _1["queries"].to_i.positive? }
      next if recent.empty?

      queries = recent.sum { _1["queries"] }
      queries.positive? ? 100.0 * recent.sum { _1["replies"] } / queries : nil
    end
    return nil if avails.empty?

    avail = avails.sum / avails.size
    {
      zone: zone,
      name: unicode_name(json.dig("group", "label"), zone),
      cc: COUNTRY[zone] || (zone.match?(/\A[a-z]{2}\z/) && zone != "eu" ? zone.upcase : nil),
      avail: avail.round(1),
      servers: avails.size,
      status: avail >= 98 ? "ok" : (avail >= 90 ? "warn" : "down"),
      spark: availability_series(servers),
      checked_at: Time.current,
      url: "https://dnsmon.ripe.net/#{zone}",
    }
  end

  # DNSMON labels IDN zones as "<unicode>. (<punycode>.)"; take the unicode part.
  def unicode_name(label, zone)
    return zone unless label

    label.split(" (").first.to_s.chomp(".").presence || zone
  end

  # Zone-wide availability per time bucket (replies/queries summed over servers),
  # downsampled for a sparkline.
  def availability_series(servers)
    totals = Hash.new { |h, k| h[k] = [0, 0] } # time => [replies, queries]
    servers.each do |s|
      Array(s["results"]).each do |b|
        q = b["queries"].to_i
        next unless q.positive?

        totals[b["time"]][0] += b["replies"].to_i
        totals[b["time"]][1] += q
      end
    end
    series = totals.keys.sort.map { |t| r, q = totals[t]; (100.0 * r / q).round(1) }
    downsample(series, SPARK_POINTS)
  end

  # The ccTLD/gTLD zones DNSMON tracks (excluding the root and e164.arpa zones).
  def zone_ids
    groups = get_json(GROUPS, timeout: 8)["groups"]
    Array(groups).filter_map { _1["id"] }
      .reject { _1.match?(/root/) || _1.include?("arpa") }
      .map { _1.chomp(".") }
  end
end

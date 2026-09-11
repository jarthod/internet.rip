module InternetHelper
  SVG_MAP = File.read("lib/assets/images/world.svg").html_safe

  # These mapping tables were created by Robinson and are what the projection is based upon
  ROB_X = [0.8487,0.84751182,0.84479598,0.840213,0.83359314,0.8257851,0.814752,0.80006949,0.78216192,0.76060494,0.73658673,0.7086645,0.67777182,0.64475739,0.60987582,0.57134484,0.52729731,0.48562614,0.45167814];
  ROB_Y = [0,0.0838426,0.1676852,0.2515278,0.3353704,0.419213,0.5030556,0.5868982,0.67182264,0.75336633,0.83518048,0.91537187,0.99339958,1.06872269,1.14066505,1.20841528,1.27035062,1.31998003,1.3523];

  # Returns the robinson projection for lat/lng coordinates
  def robinson(lat, lng, map_width: 1971, map_height: 1000)
    # map width and height are required to compute earth_radius.
    # width should equal to height*1.97165551906973 (1.97:1 ratio)
    earth_radius = (map_width/2.666269758)/2;

    # computation using positive latitude only so we store
    # the signs for later and then abs the numbers.
    lat_sign = lat <=> 0
    radian = Math::PI / 180
    idx, rest = lat.abs.divmod(5) # 5° integer division to find the table index
    ratio = rest/5.0 # and the interpolation ratio in the remainder (0...1)

    # interpolate the Robinson table
    x_ratio = ROB_X[idx]
    y_ratio = ROB_Y[idx]
    if ratio != 0 # linear interpolation
      x_ratio += ((ROB_X[idx+1]-ROB_X[idx])*ratio)
      y_ratio += ((ROB_Y[idx+1]-ROB_Y[idx])*ratio)
    end

    return [
      (x_ratio * lng * radian * earth_radius),
      (y_ratio * lat_sign * earth_radius)
    ]
  end

  # Change the coordinate system of a projected point to the one SVG & CSS uses (top left)
  # map_width and offset have been fine-tuned for the simplemaps.com free SVG world map
  def robinson_svg lat, lng, map_width: 2040, offset: [-34, -15]
    map_height = map_width / 1.97165551906973
    x, y = robinson(lat, lng, map_width: map_width, map_height: map_height)
    x = map_width / 2 + x + offset[0]
    y = map_height / 2 - y + offset[1]
    return [x.round(1), y.round(1)]
  end

  def marker x, y, size: 20, text: nil, **args
    cross = line(x-size, y, x+size, y, **args)+line(x, y-size, x, y+size, **args)
    cross += text(x+5, y+5, text, "alignment-baseline": "hanging", fill: args[:stroke]) if text
    cross
  end

  def line x1, y1, x2, y2, **args
    tag.line(x1: x1, y1: y1, x2: x2, y2: y2, **args)
  end

  # --- Plotting geographic data on the map ----------------------------------

  # Project a lat/lng and draw a circle there (used for markers & infra dots).
  def geo_circle lat, lng, r, **attrs
    x, y = robinson_svg(lat, lng)
    tag.circle(cx: x, cy: y, r: r, **attrs)
  end

  # Dot radius for the updown.io failing-checks heatmap, scaled by how many
  # failing checks are in that bucket. sqrt (not linear) so a handful of
  # busy hotspots don't dwarf everything else on the map.
  def heat_radius(count, min: 3, max: 32)
    [min + Math.sqrt(count) * 1.8, max].min.round(1)
  end

  # A country's outage-severity fill, from a 0..1 intensity: default map
  # colour → amber → red, so a barely-flagged country reads as barely
  # different from an unflagged one instead of jumping straight to full
  # amber (color-mix itself can't take three stops, hence the two branches).
  # 0 intensity already starts at 20% amber (so even the lightest flagged
  # country still shows up against the base map), ramping to pure amber at
  # AMBER_BAND, then from there on to pure red at full intensity.
  MIN_SEVERITY_PCT = 20
  AMBER_BAND = 0.6

  def severity_color(intensity)
    if intensity <= AMBER_BAND
      pct = MIN_SEVERITY_PCT + (intensity / AMBER_BAND) * (100 - MIN_SEVERITY_PCT)
      "color-mix(in srgb, var(--map-color), var(--warn-color) #{pct.round}%)"
    else
      pct = (intensity - AMBER_BAND) / (1 - AMBER_BAND) * 100
      "color-mix(in srgb, var(--warn-color), var(--down-color) #{pct.round}%)"
    end
  end

  # A dense, static layer of faint infrastructure dots (IXPs, cable landings).
  # Rendered once with the base map, so we build the markup directly for speed.
  def infra_layer points, r:, css_class:
    tag.g(class: css_class) do
      points.map { |p| geo_circle(p[:lat], p[:lng], r) }.join.html_safe
    end
  end

  # Static layer of submarine cable routes. Each cable is a MultiLineString;
  # segments are split again wherever they cross the ±180° antimeridian so the
  # projection doesn't draw a stray line straight across the map.
  def cables_layer cables
    tag.g(class: "cables") do
      cables.flat_map { |cable| cable[:segments] }.map do |segment|
        antimeridian_split(segment).map do |part|
          next if part.size < 2

          polyline(part.map { |lat, lng| robinson_svg(lat, lng) })
        end.join
      end.join.html_safe
    end
  end

  # Split a [lat, lng] path at antimeridian jumps (|Δlng| > 180°).
  def antimeridian_split segment
    segment.slice_when { |(_, lng1), (_, lng2)| (lng1 - lng2).abs > 180 }.to_a
  end

  # A tiny inline SVG sparkline from a series of numbers. The y-axis is baselined
  # at zero (with a little headroom) rather than at the series minimum, so a
  # stable series reads as a flat line and only real spikes stand out — instead
  # of amplifying tiny fluctuations to fill the whole box.
  #
  # `ceiling:`, if given, overrides the series' own max as the scale reference
  # (still with the same headroom) — for a group of sparklines that should
  # share one y-axis instead of each normalizing independently.
  def sparkline values, width: 46, height: 14, ceiling: nil, **attrs
    values = Array(values).compact
    return tag.span("", class: "spark-empty") if values.size < 2

    max = ((ceiling || values.max) * 1.15).nonzero? || 1
    step = width.to_f / (values.size - 1)
    points = values.each_with_index.map do |v, i|
      x = (i * step).round(1)
      y = (height - 1 - v / max * (height - 2)).round(1)
      "#{x},#{y}"
    end
    tag.svg(viewBox: "0 0 #{width} #{height}", preserveAspectRatio: 'none', class: "spark", **attrs) do
      tag.polyline(points: points.join(" "), fill: "none")
    end
  end

  # A short "2h"/"45m"/"3d" duration, for panels tight on width where
  # `time_ago_in_words`'s "about 2 hours" reads as clutter.
  def compact_duration(seconds)
    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    return "#{seconds / 3600}h" if seconds < 86400

    "#{seconds / 86400}d"
  end

  # A "via <source>[· extra]" attribution footer, used under panels that cite
  # an upstream data source.
  def source_line(name, url: nil, extra: nil)
    parts = ["via ", url ? link_to(name, url, target: "_blank") : name]
    parts += [" · ", extra] if extra
    tag.p(safe_join(parts), class: "source")
  end

  # CSS status class for a statuspage indicator or an up/down boolean.
  def status_class indicator
    case indicator.to_s
    when "none", "true"        then "ok"
    when "minor"               then "warn"
    when "major", "critical", "false" then "down"
    else "unknown"
    end
  end

  def text x, y, body, fill: 'white', **args
    tag.text(body, x: x, y: y, fill: fill, stroke: 'none', 'font-size': '12', **args)
  end

  def polyline points, **attrs
    tag.polyline points: points.map {_1.join(',')}.join(' '), fill: 'none', **attrs
  end

  def latitude lat
    if lat < 0
      "#{-lat}°S"
    else
      "#{lat}°N"
    end
  end

  def longitude lng
    if lng < 0
      "#{-lng}°W"
    else
      "#{lng}°E"
    end
  end
end

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

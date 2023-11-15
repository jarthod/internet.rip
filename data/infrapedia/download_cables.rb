#!/usr/bin/env ruby

require "net/http"

(0..3).each do |lng|
  (0..2).each do |lat|
    pbf = Net::HTTP.get(URI("https://www.infrapedia.com/map/cables/2/#{lng}/#{lat}.pbf"))
    filename = "cables/#{lng}-#{lat}.pbf"
    if pbf.include?("404 Not Found")
      puts "skipped #{filename} (404)"
    else
      File.write(File.join(__dir__, filename), pbf)
      puts "written #{filename} (#{pbf.bytesize/1024} kB)"
    end
  end
end

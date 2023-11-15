#!/usr/bin/env ruby

# Parse the world.svg map in this folder downloaded from https://simplemaps.com/resources/svg-world
# In order to make it ready for internet.rip:
# - Remove XML namespace for direct HTML embedding and move comment inside the SVG tag
# - Fix inconcistent country naming (sometimes in ID, sometimes in name, sometimes in class)

# https://simplemaps.com/static/demos/resources/svg-library/svgs/world.svg
require 'nokogiri'
require 'countries'

input = File.read(File.join(__dir__, "world.svg"))

# https://github.com/sparklemotion/nokogiri/wiki/Cheat-sheet
doc = Nokogiri.XML(input)
comment = doc.children.first
svg = doc.at_css('svg')
svg.prepend_child(comment)

svg.traverse do |node|
  case node.name
  when 'path'
    if node['id'] =~ /^BQ(..)$/
      node['class'] = "BQ-#{$1}" # https://en.wikipedia.org/wiki/ISO_3166-2:BQ
    elsif node['class'] == "Canary Islands (Spain)"
      iso3166_2 = 'ES-CN'
      node['class'] = iso3166_2
    elsif node['class'] == "Faeroe Islands" and country = ISO3166::Country['FO']
      node['class'] = country.alpha2
    elsif node['name'] == "Kosovo"
      node['class'] = 'XK' # user assigned
    elsif node['class'] == "Federated States of Micronesia"
      node['class'] = 'FM'
    elsif country = ISO3166::Country[node['id']]
      # puts "Country #{country} from #{node['id']}"
      node['class'] = country.alpha2
    elsif country = ISO3166::Country.find_country_by_any_name(node['name'] || node['class'])
      # puts "Country #{country} from #{node['name'] || node['class']}"
      node['class'] = country.alpha2
    else
      puts "Couldn't find country with #{node['id']}, #{node['name']}, #{node['class']}"
    end
    node.delete('id')
    node.delete('name')
  when 'circle'
    node.remove
  else
  end
end

File.write(File.join(__dir__, "../../lib/assets/images/world.svg"), svg)

source "https://rubygems.org"

ruby "4.0.1"

gem "rails", "~> 8.1.0"
gem "propshaft"
gem "sqlite3", "~> 2.1"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "nokogiri"
# gem "turbo-rails"
gem "bootsnap", require: false

group :development, :test do
  gem "debug", platforms: %i[ mri windows ]
end

group :development do
  gem "web-console"
  gem "error_highlight", ">= 0.4.0", platforms: [:ruby]
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
end

group :production do
  # HTTP caching middleware: serves repeat GETs to publicly-cacheable actions
  # straight from an in-process cache. See config/environments/production.rb.
  gem "rack-cache", require: "rack/cache"
end

gem "countries", "~> 8.1"

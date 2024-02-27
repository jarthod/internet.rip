source "https://rubygems.org"

ruby "3.1.2"

gem "rails", "~> 7.1.3"
gem "propshaft"
gem "sqlite3", "~> 1.5"
gem "puma", ">= 5.0"
gem "importmap-rails"
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

require 'rubygems'
require 'bundler'
require 'rack/test'

Bundler.require(:default, :test)

require File.join(File.dirname(__FILE__), '..', 'shipstation_app.rb')

Dir['./spec/support/**/*.rb'].each &method(:require)

Sinatra::Base.environment = 'test'

ENV['SHIPSTATION_AUTHORIZATION'] ||= 'auth'
ENV['SHIPSTATION_MASHAPE_KEY'] ||= 'key'
ENV['SHIPSTATION_STORE_ID'] ||= '123'

# some sort of digest key on request url, not sure
ENV['SHIPSTATION_AUTH'] ||= 'auth'
ENV['SHIPSTATION_KEY'] ||= 'key'

VCR.configure do |c|
  c.allow_http_connections_when_no_cassette = false
  c.cassette_library_dir = 'spec/cassettes'
  c.hook_into :webmock

  # hack to avoid data in binary on cassetes
  # c.force_utf8_encoding = true

  c.filter_sensitive_data("SHIPSTATION_AUTHORIZATION") { ENV["SHIPSTATION_AUTHORIZATION"] }
  c.filter_sensitive_data("SHIPSTATION_MASHAPE_KEY") { ENV["SHIPSTATION_MASHAPE_KEY"] }
  c.filter_sensitive_data("SHIPSTATION_STORE_ID") { ENV["SHIPSTATION_STORE_ID"] }

  c.filter_sensitive_data("SHIPSTATION_AUTH") { ENV["SHIPSTATION_AUTH"] }
  c.filter_sensitive_data("SHIPSTATION_KEY") { ENV["SHIPSTATION_KEY"] }
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
end

def app
  ShipStationApp
end

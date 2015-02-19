require 'rubygems'
require 'bundler'
require 'rack/test'

Bundler.require(:default, :test)

require File.join(File.dirname(__FILE__), '..', 'shipstation_app.rb')

Dir['./spec/support/**/*.rb'].each &method(:require)

Sinatra::Base.environment = 'test'

ENV['SHIPSTATION_AUTHORIZATION'] ||= 'auth'

VCR.configure do |c|
  c.allow_http_connections_when_no_cassette = false
  c.cassette_library_dir = 'spec/cassettes'
  c.hook_into :webmock

  # hack to avoid data in binary on cassetes
  # c.force_utf8_encoding = true

  c.filter_sensitive_data("SHIPSTATION_AUTHORIZATION") { ENV["SHIPSTATION_AUTHORIZATION"] }
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
end

def app
  ShipStationApp
end

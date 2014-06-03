require 'rubygems'
require 'bundler'
require 'rack/test'

Bundler.require(:default, :test)

require File.join(File.dirname(__FILE__), '..', 'shipstation_app.rb')

Dir['./spec/support/**/*.rb'].each &method(:require)

Sinatra::Base.environment = 'test'

VCR.configure do |c|
  c.cassette_library_dir = 'spec/cassettes'
  c.hook_into :webmock
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
end

def app
  ShipStationApp
end

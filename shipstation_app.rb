require 'sinatra'
require 'json'
require 'active_support/core_ext/hash/indifferent_access'

class ShipStationApp < Sinatra::Base
  post '/add_order' do
    content_type :json
    payload = JSON.parse(request.body.read).with_indifferent_access
    request_id = payload[:request_id]
    sms = payload[:order]
    params = payload[:parameters]

    begin
      # create the order here
    rescue => e
      # tell the hub about the unsuccessful delivery attempt
      status 500
      return { request_id: request_id, summary: "Unable to create order. Error: #{e.message}" }.to_json + "\n"
    end

    # acknowledge the successful delivery of the message
    { request_id: request_id, summary: "Order created in shipstation" }.to_json + "\n"
  end
end
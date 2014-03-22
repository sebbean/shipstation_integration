require 'sinatra'
require 'json'
require 'active_support/core_ext/hash/indifferent_access'
require 'shipstation_ruby'

require 'pry'

class ShipStationApp < Sinatra::Base
  post '/add_order' do
    content_type :json
    payload = JSON.parse(request.body.read).with_indifferent_access
    request_id = payload[:request_id]
    order = payload[:order]
    params = payload[:parameters]

    begin
      #client = ShipStationRuby::Client.new(params[:username], params[:password])
      auth = {:username => params[:username], :password => params[:password]}
      client = OData::Service.new("https://data.shipstation.com/1.1", auth)

      # create the order
      resource = new_order(order)
      client.AddToOrders(resource)
      result = client.save_changes

      # create the line items
      @shipstation_id = result.first.OrderID
      new_order_items(order[:line_items], @shipstation_id).each do |resource|
        client.AddToOrderItems(resource)
      end
      result = client.save_changes

    rescue => e
      # tell the hub about the unsuccessful create attempt
      status 500
      return { request_id: request_id, summary: "Unable to create ShipStation order. Error: #{e.message}" }.to_json + "\n"
    end

    # acknowledge the successful adding of the order
    response = {
      request_id: request_id,
      summary: "Order created in ShipStation: #{@shipstation_id}",
      order: {id: order[:id], shipstation_id: @shipstation_id}
    }

    response.to_json + "\n"
  end

  private
  def new_order(order)
    raise ":shipping_address required" unless order[:shipping_address]
    resource = Order.new
    resource.BuyerEmail = order[:email]
    resource.MarketplaceID = 0
    #resource.NotesFromBuyer = "Will pick up"
    resource.OrderDate = order[:placed_on]
    resource.OrderNumber = order[:id]
    resource.OrderStatusID = 2
    resource.OrderTotal = order[:totals][:order].to_s
    #resource.RequestedShippingService = "USPS Priority Mail"
    resource.ShipCity = order[:shipping_address][:city]
    #resource.ShipCompany = "FOO" # company name on shipping address
    resource.ShipCountryCode = order[:shipping_address][:country]
    resource.ShipName = order[:shipping_address][:firstname] + " " + order[:shipping_address][:lastname]
    resource.ShipPhone = order[:shipping_address][:phone]
    resource.ShipPostalCode = order[:shipping_address][:zipcode]
    resource.ShipState = order[:shipping_address][:state]
    resource.ShipStreet1 = order[:shipping_address][:address1]
    resource.ShipStreet2 = order[:shipping_address][:address2]
    resource
  end

  def new_order_items(line_items, shipstation_id)
    item_resources = []

    line_items.each do |item|
      resource = OrderItem.new
      resource.OrderID = shipstation_id
      resource.Quantity = item[:quantity]
      resource.SKU = item[:product_id]
      resource.Description = item[:name]
      resource.UnitPrice = item[:price].to_s
      item_resources << resource
    end
    item_resources
  end
end
class ShipStationApp < EndpointBase::Sinatra::Base
  set :public_folder, 'public'
  set :logging, true

  Honeybadger.configure do |config|
    config.api_key = ENV['HONEYBADGER_KEY']
    config.environment_name = ENV['RACK_ENV']
  end

  post '/add_shipment' do
    # Shipstation wants orders and then it creates shipments. This integration assumes the
    # shipments are already split and will just create "orders" that are identical to the
    # storefront concept of a shipment.

    begin
      authenticate_shipstation

      @shipment = @payload[:shipment]

      # create the order
      resource = new_order(@shipment)
      @client.AddToOrders(resource)
      shipstation_response = @client.save_changes

      @shipstation_id = shipstation_response.first.OrderID

      # create the line items
      new_items(@shipment[:items], @shipstation_id).each do |resource|
        @client.AddToOrderItems(resource)
      end
      @client.save_changes

    rescue => e
      # tell Honeybadger
      log_exception(e)

      # tell the hub about the unsuccessful create attempt
      result 500, "Unable to send shipment to ShipStation. Error: #{e.message}"
    end

    # return a partial order object with the shipstation id
    # add_object :order, {id: @order[:id], shipstation_id: @shipstation_id}
    result 200, "Shipment transmitted to ShipStation: #{@shipstation_id}"
  end

  post '/get_shipments' do

    begin
      authenticate_shipstation

      # Shipstation doesn't record time information - just date, so round the parameter down
      since = Time.parse(@config[:since]).utc.beginning_of_day.iso8601

      @client.Shipments.filter("ModifyDate ge datetime'#{since}' and ShipDate ne null")
      shipstation_result = @client.execute

      # TODO - get shipping carrier, etc.
      shipstation_result.each do |resource|

        # lookup the shipment (aka order) number that we originally supplied shipstation with
        @client.Orders.filter("OrderID eq #{resource.OrderID.to_s}")

        order_resource = @client.execute.first
        shipment_number = order_resource.OrderNumber

        add_object :shipment, {
          id: shipment_number,
          tracking: resource.TrackingNumber,
          shipstation_id: resource.ShipmentID.to_s,
          status: "shipped",
          shipping_address: {
            address1:  order_resource.ShipStreet1,
            address2:  order_resource.ShipStreet2,
            zipcode:   order_resource.ShipPostalCode,
            city:      order_resource.ShipCity,
            state:     order_resource.ShipState,
            country:   order_resource.ShipCountryCode,
            phone:     order_resource.ShipPhone
          }
        }
      end
      @kount = shipstation_result.count

      # return current timestamp so parameter updates on hub side
      # NOTE: shipstation doesn't provide detail beyond date so we need to round it down in order
      # to not miss any shipments
      add_parameter 'since', Time.now.utc.beginning_of_day
    rescue => e
      # tell Honeybadger
      log_exception(e)

      # tell the hub about the unsuccessful get attempt
      result 500, "Unable to get shipments from ShipStation. Error: #{e.message}"
    end

    result 200, "Retrieved #{@kount} shipments from ShipStation"
  end

  private

  def authenticate_shipstation
    auth = {:username => @config[:username], :password => @config[:password]}
    @client = OData::Service.new("https://data.shipstation.com/1.1", auth)
  end

  def get_service_id(method_name)
    service_id = case method_name
      when 'UPS Ground' then 26 #UPS Ground
      when 'UPS Express' then 31 #UPS Next Day Air Saver
      when 'DHL International' then 148 #Express Worldwide
    end
  end

  def get_carrier_id(carrier_name)
    carrier_id = case carrier_name
      when "UPS" then 3
      when "DHL" then 13
      else 0
    end
  end

  def new_order(shipment)
    resource = Order.new
    resource.BuyerEmail = shipment[:email]
    resource.NotesFromBuyer = shipment[:delivery_instructions]
    resource.PackageTypeID = 3 # This is equivalent to 'Package'
    resource.OrderNumber = shipment[:id]
    if shipment[:status] == 'hold'
      resource.OrderStatusID = 5
      resource.HoldUntil = shipment[:hold_until]
    else
      resource.OrderStatusID = 2
    end
    resource.StoreID = @config[:shipstation_store_id] unless @config[:shipstation_store_id].blank?
    resource.ShipCity = shipment[:shipping_address][:city]
    resource.ShipCountryCode = shipment[:shipping_address][:country]
    resource.ProviderID = get_carrier_id(shipment[:shipping_carrier])
    resource.ServiceID = get_service_id(shipment[:shipping_method])
    resource.ShipName = shipment[:shipping_address][:firstname] + " " + shipment[:shipping_address][:lastname]
    resource.ShipPhone = shipment[:shipping_address][:phone]
    resource.ShipPostalCode = shipment[:shipping_address][:zipcode]
    resource.ShipState = shipment[:shipping_address][:state]
    resource.ShipStreet1 = shipment[:shipping_address][:address1]
    resource.ShipStreet2 = shipment[:shipping_address][:address2]
    # resource.MarketplaceID = @config[:marketplace_id]
    resource.OrderDate = shipment[:created_at]
    resource.PayDate = shipment[:created_at]
    resource.OrderTotal = shipment[:order_total]
    resource
  end

  def new_items(line_items, shipstation_id)
    item_resources = []

    line_items.each do |item|
      resource = OrderItem.new
      resource.OrderID = shipstation_id
      resource.Quantity = item[:quantity]
      resource.SKU = item[:product_id]
      resource.Description = item[:name]
      resource.UnitPrice = item[:price].to_s
      resource.ThumbnailUrl = item[:image_url]

      if item[:properties]
        properties = ""
        item[:properties].each do |key, value|
          properties += "#{key}:#{value}\n"
        end
        resource.Options = properties
      end

      item_resources << resource
    end
    item_resources
  end
end

class ShipStationApp < EndpointBase::Sinatra::Base
  set :public_folder, 'public'

  post '/add_order' do

    begin
      authenticate_shipstation
      @order = @payload[:order]

      # create the order
      resource = new_order(@order)
      @client.AddToOrders(resource)
      shipstation_response = @client.save_changes

      # create the line items
      @shipstation_id = shipstation_response.first.OrderID

      new_order_items(@order[:line_items], @shipstation_id).each do |resource|
        @client.AddToOrderItems(resource)
      end
      @client.save_changes

    rescue => e
      # tell the hub about the unsuccessful create attempt
      result 500, "Unable to create ShipStation order. Error: #{e.message}"
    end

    # return a partial order object with the shipstation id
    add_object :order, {id: @order[:id], shipstation_id: @shipstation_id}
    result 200, "Order created in ShipStation: #{@shipstation_id}"
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
        add_object :shipment, {
          id: resource.ShipmentID.to_s,
          tracking: resource.TrackingNumber,
          order_id: resource.OrderID.to_s
        }
      end
      @kount = shipstation_result.count

      # return current timestamp so parameter updates on hub side
      # NOTE: shipstation doesn't provide detail beyond date so we need to round it down in order
      # to not miss any shipments
      add_parameter 'since', Time.now.utc.beginning_of_day
    rescue => e
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
      when 'UPS Express' then 32 #UPS Next Day Air
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

  def new_order(order)
    raise ":shipping_address required" unless order[:shipping_address]
    resource = Order.new
    resource.BuyerEmail = order[:email]
    resource.MarketplaceID = @config[:marketplace_id]
    resource.NotesFromBuyer = order[:delivery_instructions]
    resource.OrderDate = order[:placed_on]
    resource.PayDate = order[:placed_on]
    resource.OrderNumber = order[:id]
    resource.OrderStatusID = 2
    resource.StoreID = @config[:shipstation_store_id]
    resource.OrderTotal = order[:totals][:order].to_s
    #resource.RequestedShippingService = "USPS Priority Mail"
    resource.ShipCity = order[:shipping_address][:city]
    #resource.ShipCompany = "FOO" # company name on shipping address
    resource.ShipCountryCode = order[:shipping_address][:country]
    resource.ProviderID = get_carrier_id(order[:shipping_carrier])
    resource.ServiceID = get_service_id(order[:shipping_method])
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

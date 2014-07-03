class ShipStationApp < EndpointBase::Sinatra::Base
  set :public_folder, 'public'
  set :logging, true

  STATUS_ON_HOLD           = 5
  STATUS_CANCELLED         = 4
  STATUS_AWAITING_SHIPMENT = 2

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

  post '/update_shipment' do
    begin
      authenticate_shipstation

      @shipment = @payload[:shipment]

      # NOP if shipment has been already shipped / cancelled?
      # possibly to avoid infinite loops with update_shipment <-> get_shipments
      if @shipment[:status] == "shipped" || @shipment[:status] =~ /cancell?ed/
        return result 200, "Can't update Order when status is #{ @shipment[:status] }"
      end

      @client.Orders.filter("OrderNumber eq '#{ @shipment[:id] }'")
      if order = @client.execute.first

        # update order
        resource = new_order(@shipment, order)
        @client.update_object(resource)
        @client.save_changes

        # update items
        @client.OrderItems.filter("OrderID eq #{resource.OrderID}")
        items = @client.execute

        # delete old ones
        items.each do |item|
          @client.delete_object(item)
        end

        # add current ones
        new_items(@shipment[:items], resource.OrderID).each do |resource|
          @client.AddToOrderItems(resource)
        end
        @client.save_changes

        result 200, "Shipment update transmitted in ShipStation: #{ resource.OrderID }"
      else
        result 200, "Order #{ @shipment[:id] } not found in ShipStation."
      end
    rescue => e
      # tell Honeybadger
      log_exception(e)

      # tell the hub about the unsuccessful get attempt
      result 500, "Unable to update shipment in ShipStation. Error: #{e.message}"
    end
  end

  post '/get_shipments' do

    begin
      authenticate_shipstation

      since = Time.parse(@config[:since]).iso8601

      @client.Shipments.filter("CreateDate ge datetime'#{since}'")
      shipstation_result = @client.execute

      # TODO - get shipping carrier, etc.
      shipstation_result.each do |resource|

        # lookup the shipment (aka order) number that we originally supplied shipstation with
        @client.Orders.filter("OrderID eq #{resource.OrderID.to_s}")

        order_resource = @client.execute.first
        shipment_number = order_resource.OrderNumber

        full_name = order_resource.ShipName.to_s
        firstname = full_name.split(" ").first
        lastname = full_name.split(" ").last

        add_object :shipment, {
          id: shipment_number,
          tracking: resource.TrackingNumber,
          shipstation_id: resource.ShipmentID.to_s,
          status: "shipped",
          shipping_address: {
            firstname: firstname,
            lastname:  lastname,
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

      # ShipStation appears to be recording their timestamps in local (PST) time but storing that timestamp
      # as UTC (so it's basically 7-8 hours off the correct time (depending on daylight savings). To compensate
      # for this the timestamp we use for "now" should be adjusted accordingly.
      now = (Time.now + Time.zone_offset("PDT")).utc.iso8601

      # Tell Wombat to use the current time as the 'high watermark' the next time it checks
      add_parameter 'since', now
    rescue => e
      # tell Honeybadger
      log_exception(e)

      # tell the hub about the unsuccessful get attempt
      result 500, "Unable to get shipments from ShipStation. Error: #{e.message}"
    end

    set_summary "Retrieved #{@kount} shipments from ShipStation" if @kount > 0
    result 200
  end

  private

  def authenticate_shipstation
    auth = {:username => @config[:username], :password => @config[:password]}
    @client = OData::Service.new("https://data.shipstation.com/1.1", auth)
  end

  def get_service_id(method_name)
    @client.ShippingServices.filter("Name eq '#{ method_name }'")
    if method = @client.execute.first
      method.ShippingServiceID
    else
      raise "Shipping method '#{ method_name }' not found in ShipStation"
    end
  end

  def get_carrier_id(carrier_name)
    @client.ShippingProviders.filter("Name eq '#{carrier_name}'")
    if carrier = @client.execute.first
      carrier.CarrierID
    else
      raise "Carrier '#{ carrier_name }' not found in ShipStation"
    end
  end

  def new_order(shipment, resource = Order.new)
    resource.BuyerEmail     = shipment[:email]
    resource.NotesFromBuyer = shipment[:delivery_instructions]
    resource.PackageTypeID  = 3 # This is equivalent to 'Package'
    resource.OrderNumber    = shipment[:id]

    case shipment[:status]
    when 'hold'
      resource.OrderStatusID = STATUS_ON_HOLD
      resource.HoldUntil = shipment[:hold_until]
    when /cancell?ed/
      resource.OrderStatusID = STATUS_CANCELLED
    else
      resource.OrderStatusID = STATUS_AWAITING_SHIPMENT
    end

    resource.StoreID         = @config[:shipstation_store_id] unless @config[:shipstation_store_id].blank?
    resource.ShipCity        = shipment[:shipping_address][:city]
    resource.ShipCountryCode = shipment[:shipping_address][:country]
    resource.ProviderID      = get_carrier_id(shipment[:shipping_carrier])
    resource.ServiceID       = get_service_id(shipment[:shipping_method])
    resource.ShipName        = shipment[:shipping_address][:firstname] + " " + shipment[:shipping_address][:lastname]
    resource.ShipPhone       = shipment[:shipping_address][:phone]
    resource.ShipPostalCode  = shipment[:shipping_address][:zipcode]
    resource.ShipState       = shipment[:shipping_address][:state]
    resource.ShipStreet1     = shipment[:shipping_address][:address1]
    resource.ShipStreet2     = shipment[:shipping_address][:address2]
    resource.OrderDate       = shipment[:created_at] || Time.now.utc
    resource.PayDate         = shipment[:created_at] || Time.now.utc
    resource.OrderTotal      = shipment[:order_total].to_f.to_s
    resource
  end

  def new_items(line_items, shipstation_id)
    line_items.map do |item|
      resource              = OrderItem.new
      resource.OrderID      = shipstation_id
      resource.Quantity     = item[:quantity]
      resource.SKU          = item[:product_id]
      resource.Description  = item[:name]
      resource.UnitPrice    = item[:price].to_s
      resource.ThumbnailUrl = item[:image_url]

      if item[:properties]
        properties = ""
        item[:properties].each do |key, value|
          properties += "#{key}:#{value}\n"
        end
        resource.Options = properties
      end

      resource
    end
  end
end

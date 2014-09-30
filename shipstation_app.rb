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
      order = populate_order(@payload[:shipment])

      response = Unirest.post "https://shipstation.p.mashape.com/Orders/CreateOrder",
                              headers: {"Authorization" => "Basic #{@config[:authorization]}", "X-Mashape-Key" => @config[:mashape_key], "content-type" => "application/json"},
                              parameters: order.to_json

      raise response.body["Message"] if response.code == 400
      if error = response.body["ExceptionMessage"]
        raise error
      end

      @shipstation_id = response.body["orderId"]

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

      # NOP if shipment has been already shipped
      # possibly to avoid infinite loops with update_shipment <-> get_shipments
      if @shipment[:status] == "shipped"
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

      # ShipStation appears to be recording their timestamps in local (PST) time but storing that timestamp
      # as UTC (so it's basically 7-8 hours off the correct time (depending on daylight savings). To compensate
      # for this the timestamp we use for "since" should be adjusted accordingly.
      since_time = (Time.parse(@config[:since]) + Time.zone_offset("PDT")).utc

      since_date = "#{since_time.year}-#{since_time.month}-#{since_time.day}"

      response = Unirest.get "https://shipstation.p.mashape.com/Shipments/List?page=1&pageSize=500&shipdatestart=#{since_date}",
                             headers: {"Authorization" => "Basic #{@config[:authorization]}", "X-Mashape-Key" => @config[:mashape_key]}

      if error = response.body["ExceptionMessage"]
        raise error
      end

      @kount = 0

      response.body["shipments"].each do |shipment|
        # ShipStation cannot give us shipments based on time (only date) so we need to filter the list of
        # shipments down further using the timestamp provided
        next unless Time.parse(shipment["createDate"] + "Z") > since_time

        @kount += 1
        shipTo = shipment["shipTo"]

        add_object :shipment, {
          id: shipment["orderId"],
          tracking: shipment["trackingNumber"],
          shipstation_id: shipment["shipmentId"],
          status: "shipped",
          shipping_address: {
            firstname: shipTo["name"].split(" ").first,
            lastname:  shipTo["name"].split(" ").last,
            address1:  shipTo["street1"],
            address2:  shipTo["street2"],
            zipcode:   shipTo["postalCode"],
            city:      shipTo["city"],
            state:     shipTo["state"],
            country:   shipTo["country"],
            phone:     shipTo["phone"]
          }
        }

        @new_since = Time.parse(shipment["createDate"] + "PDT") + 1.second
      end

      # # Tell Wombat to use the current time as the 'high watermark' the next time it checks
      add_parameter 'since', @new_since || Time.now
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

  def map_carrier(carrier_name)
    response = Unirest.get "https://shipstation.p.mashape.com/Carriers",
                           headers: {"Authorization" => "Basic #{@config[:authorization]}", "X-Mashape-Key" => @config[:mashape_key]}

    raise "Unable to retrieve carrier code for #{carrier_name}" unless response.code == 200

    response.body.each do |carrier|
      return carrier["code"] if carrier["name"] == carrier_name
    end

    raise "There is no carrier named '#{carrier_name}' configured with this ShipStation account"
  end

  def map_service(carrier_code, service_name)
    response = Unirest.get "https://shipstation.p.mashape.com/Carriers/ListServices?carrierCode=#{carrier_code}",
                           headers: {"Authorization" => "Basic #{@config[:authorization]}", "X-Mashape-Key" => @config[:mashape_key]}

    raise "Unable to retrieve service codes for #{carrier_code}" unless response.code == 200

    response.body.each do |service|
      return service["code"] if service["name"] == service_name
    end

    raise "There is no service named '#{service_name}' associated wtih the carrier_code of '#{carrier_code}'"
  end

  def populate_order(shipment)
    carrier_code = map_carrier(shipment[:shipping_carrier]) #
    order = {
      "customerEmail" => shipment[:email],
      "customerUsername" => shipment[:email],
      "orderNumber" => shipment[:id], #required
      "orderDate" => shipment[:created_at] || Time.now,
      "paymentDate" => shipment[:created_at] || Time.now,
      "orderStatus" => map_status(shipment[:status]), #required: hold, canceled, awaiting_shipment
      "shipTo" => populate_address(shipment[:shipping_address]), #required (see populate_address for details)
      "billTo" => populate_address(shipment[:billing_address]) || populate_address(shipment[:shipping_address]),
      "customerNotes" => shipment[:delivery_instructions],
      "packageCode" => 'package',
      "advancedOptions" => populate_advanced(shipment),
      "carrierCode" => carrier_code,
      "serviceCode" => map_service(carrier_code, shipment[:shipping_method]), #required if shipping_carrier is present
      "items" => populate_items(shipment[:items])
    }
  end

  def populate_advanced(shipment)
    {
      "storeId" => @config[:shipstation_store_id],
      "customfield1" => shipment[:custom_field_1],
      "customfield2" => shipment[:custom_field_2],
      "customfield3" => shipment[:custom_field_3]
    }
  end

  def populate_items(line_items)
    return if line_items.nil?
    line_items.map do |item|
      {
        "lineItemKey" => nil,
        "sku" => item[:product_id],
        "name" => item[:name],
        "imageUrl" => item[:image_url],
        "quantity" => item[:quantity],
        "unitPrice" => item[:price]
      }
    end
  end

  def populate_address(address)
    return if address.nil?
    {
      :name => address[:firstname] + " " + address[:lastname], #required
      :street1 => address[:address1], #required
      :street2 => address[:address2],
      :street3 => address[:address3],
      :city => address[:city], #required
      :state => address[:state], #required
      :postalCode => address[:zipcode], #required
      :country => address[:country], #required
      :phone => address[:phone]
    }
  end

  def map_status(status)
    case status
    when 'hold'
      'on_hold'
    when '/cancell?ed/'
      'canceled'
    else
      'awaiting_shipment'
    end
  end

end

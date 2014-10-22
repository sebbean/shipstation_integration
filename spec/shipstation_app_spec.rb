require 'spec_helper'

describe ShipStationApp do
  def json_response
    JSON.parse(last_response.body)
  end

  let(:config) do
    {
      "username" => 'cucamonga',
      "password" => 'ohyeah'
    }
  end

  describe 'POST /get_shipments' do
    let(:request) do
      {
        request_id: '1234567',
        parameters: config.merge(since: "2014-06-03T00:38:23Z")
      }
    end

    it 'returns shipments' do
      VCR.use_cassette('get_shipments') do
        post '/get_shipments', request.to_json, {}
      end

      expect(json_response["summary"]).to match /Received * shipments from Shipstation/i
      expect(json_response["shipments"].count).to eq 1
      expect(json_response["shipments"][0]["id"]).to eq "bruno-custom-international-test3"

      expect(last_response.status).to eq 200
    end

    it "doesnt set summary if no shipments found" do
      response = double("Response", body: { "shipments" => [] }).as_null_object
      expect(Unirest).to receive(:get).and_return response

      post '/get_shipments', request.to_json, {}
      expect(json_response["summary"]).to be_nil
      expect(last_response.status).to eq 200
    end
  end

  describe 'POST /add_shipment' do
    let(:request) do
      {
        request_id: '123',
        parameters: config,
        shipment: {
          id: "bruno-custom-shipment",
          shipping_address: {
            firstname: "Bruno",
            lastname: "Buccolo",
            address1: "Rua Canario, 183",
            address2: "",
            zipcode: "01155-030",
            city: "São Paulo",
            state: "SP",
            country: "BR",
            phone: "5511955111091"
          },
          items: [{
              name: "Spree T-Shirt",
              product_id: "SPREE-T-SHIRT",
              quantity: 9,
              price: 9,
              options: {}
          }],
          shipping_carrier: "UPS",
          shipping_method: "UPS Ground",
          created_at: "2014-06-02T15:38:23Z"
        }
      }
    end

    it 'creates a shipment with a requested_shipping_service' do
      VCR.use_cassette('add_shipment_requested_shipping_service') do
        request[:shipment][:requested_shipping_service] = "Cucamonga Express"

        post '/add_shipment', request.to_json, {}
      end

      expect(json_response["summary"]).to eq "Shipment transmitted to ShipStation: 66340085"
    end

    it 'creates a shipment' do
      VCR.use_cassette('add_shipment') do
        post '/add_shipment', request.to_json, {}
      end

      expect(json_response["summary"]).to eq "Shipment transmitted to ShipStation: 109829141"
    end
  end

  describe 'POST /update_shipment' do
    let(:request) do
      {
        request_id: '123',
        parameters: config,
        shipment: {
          id: "bruno-custom-international-test2",
          shipping_address: {
            firstname: "Brunow",
            lastname: "Buccolo",
            address1: "Rua Canario, 183",
            address2: "",
            zipcode: "01155-030",
            city: "São Paulo",
            state: "SP",
            country: "BR",
            phone: "5511955111091"
          },
          items: [{
              name: "Spree T-Shirt",
              product_id: "SPREE-T-SHIRT",
              quantity: 10,
              price: 9,
              options: {}
          }],
          shipping_carrier: "UPS",
          shipping_method: "UPS Standard",
          created_at: "2014-06-02T15:38:23Z"
        }
      }
    end

    it 'updates a shipment' do
      VCR.use_cassette('update_shipment') do
        post '/update_shipment', request.to_json, {}
      end

      expect(json_response["summary"]).to eq "Shipment update transmitted in ShipStation: 109780892"
    end
  end
end

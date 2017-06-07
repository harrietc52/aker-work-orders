require 'rails_helper'

RSpec.describe WorkOrderValidatorService do
  before do
    @work_order = create :work_order, status: 'active'
    @msg = build :work_order_completion_message_json
    @msg[:work_order][:work_order_id] = @work_order.id
    @validator = WorkOrderValidatorService.new(@work_order, @msg)

    allow(@work_order).to receive(:has_materials?).and_return true

    query_double = double('query', first:nil)

    allow(MatconClient::Container).to receive(:where).and_return(query_double)

    @material_schema = %Q{
      {"required": ["gender", "donor_id", "phenotype", "supplier_name", "common_name"], "type": "object", "properties": {"gender": {"required": true, "type": "string", "enum": ["male", "female", "unknown"]}, "date_of_receipt": {"type": "string", "format": "date"}, "material_type": {"enum": ["blood", "dna"], "type": "string"}, "donor_id": {"required": true, "type": "string"}, "phenotype": {"required": true, "type": "string"}, "supplier_name": {"required": true, "type": "string"}, "common_name": {"required": true, "type": "string", "enum": ["Homo Sapiens", "Mouse"]}, "parents": {"type": "list", "schema": {"type": "uuid", "data_relation": {"field": "_id", "resource": "materials", "embeddable": true}}}, "owner_id": {"type": "string"}}}
    }

    @container_schema = %Q{
      {"required": ["num_of_cols", "num_of_rows", "col_is_alpha", "row_is_alpha"], "type": "object", "properties": {"num_of_cols": {"max": 9999, "col_alpha_range": true, "required": true, "type": "integer", "min": 1}, "barcode": {"non_aker_barcode": true, "minlength": 6, "unique": true, "type": "string"}, "num_of_rows": {"row_alpha_range": true, "max": 9999, "required": true, "type": "integer", "min": 1}, "col_is_alpha": {"required": true, "type": "boolean"}, "print_count": {"max": 9999, "required": false, "type": "integer", "min": 0}, "row_is_alpha": {"required": true, "type": "boolean"}, "slots": {"uniqueaddresses": true, "type": "list", "schema": {"type": "dict", "schema": {"material": {"type": "uuid", "data_relation": {"field": "_id", "resource": "materials", "embeddable": true}}, "address": {"type": "string", "address": true}}}}}}
    }

    stub_request(:get, "#{Rails.configuration.material_url}materials/json_schema").
         to_return(status: 200, body: @material_schema, headers: {})

    stub_request(:get, "#{Rails.configuration.material_url}containers/json_schema").
         to_return(status: 200, body: @container_schema, headers: {})

    stub_request(:get, "#{Rails.configuration.material_url}materials/json_patch_schema").
        to_return(status: 200, body: @material_schema, headers: {})
  end

  def expect_error(msg)
    expect(@validator.validate?).to eq(false)
    expect(@validator.errors).not_to be_empty
    expect(@validator.errors[:msg]).to match(msg)
  end

  describe "#validate?" do
    it "fails when the work order is not in the right status" do
      @work_order.status = 'completed'
      expect_error(/work order.*active/i)
    end
    it "fails when the json schema validation is not valid" do
      @msg['extra_info']='another extra info'
      expect_error(/extra_info/i)
    end
    it "fails when the work order does not exists" do
      @msg[:work_order][:work_order_id] = -1
      expect_error(/work order.*exist/i)
    end
    it "fails when the work order updated materials are not the same defined in the message" do
      allow(@work_order).to receive(:has_materials?).and_return false
      expect_error(/materials.*work order/i)
    end

    it "fails when the updated materials has a repeated material" do
      um = @msg[:work_order][:updated_materials]
      um.push(um.first)
      expect_error(/material.*repeated/)
    end

    it "fails when the containers have changed" do
      different_container = double('container', num_of_rows: 5, num_of_cols: 6, row_is_alpha: true, col_is_alpha: false)
      query_double = double('query', first:different_container)
      allow(MatconClient::Container).to receive(:where).with(barcode: "XYZ-123").and_return(query_double)

      expect_error(/container.*different/i)
    end
    it "fails when a container is specified twice" do
      c = @msg[:work_order][:containers]
      c.push(c.first)
      expect_error(/barcode.*unique/i)
    end
    it "fails when a material location without address is repeated" do
      mat = @msg[:work_order][:new_materials]
      mat.first[:container].delete(:address)
      mat.push(mat.first)

      expect_error(/materials.*location/i)
    end
    it "fails when a material location with address is repeated" do
      mat = @msg[:work_order][:new_materials]
      mat.push(mat.first)

      expect_error(/materials.*location/i)
    end
    it "allows two materials in different addresses of one container" do
      mat = @msg[:work_order][:new_materials]
      new_mat = mat.first.clone
      new_mat[:container] = {
        barcode: "XYZ-123",
        address: "A:2",
      }
      mat.push(new_mat)

      expect(@validator.validate?).to eq(true)
      expect(@validator.errors).to be_empty
    end
    it "fails when a material location is given with and without an address" do
      mat = @msg[:work_order][:new_materials]
      new_mat = mat.first.clone
      new_mat[:container] = {
        barcode: "XYZ-123"
      }
      mat.push(new_mat)

      expect_error(/materials.*location/i)
    end
    it "fails when a material location is missing from containers" do
      mat = @msg[:work_order][:new_materials]
      new_mat = mat.first.clone
      new_mat[:container] = {
        barcode: "ABC-XYZ"
      }
      mat.push(new_mat)

      expect_error(/locations.*containers/i)
    end

    it "fails when a superfluous container is specified" do
      conts = @msg[:work_order][:containers]
      new_cont = conts.first.clone
      new_cont[:barcode] = 'ABC-XYZ'
      conts.push(new_cont)

      expect_error(/containers.*locations/i)
    end

    it "succeeds when container is found and fields are correct" do
      remote_container = double('container', num_of_rows: 4, num_of_cols: 6, row_is_alpha: true, col_is_alpha: false)
      query_double = double('query', first: remote_container)
      allow(MatconClient::Container).to receive(:where).with(barcode: "XYZ-123").and_return(query_double)

      expect(@validator.validate?).to eq(true)
      expect(@validator.errors).to be_empty
    end

    it "succeeds when the data is right" do
      expect(@validator.validate?).to eq(true)
      expect(@validator.errors).to be_empty
    end
  end
end

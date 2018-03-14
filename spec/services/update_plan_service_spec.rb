require 'rails_helper'

RSpec.describe UpdatePlanService do
  let(:plan) { create(:work_plan) }
  let(:messages) { {} }
  let(:dispatch) { false }
  let(:params) { }
  let(:service) { UpdatePlanService.new(params, plan, dispatch, messages) }
  let(:catalogue) { create(:catalogue) }
  let(:product) { create(:product, catalogue: catalogue) }
  let(:project) { make_project(18, 'S1234-0') }
  let(:set) { make_set(false, true, locked_set) }
  let(:locked_set) { make_set(false, true) }
  let(:processes) { create_processes(product) }

  before(:each) do
    stub_billing_facade
    extra_stubbing

    @result = service.perform
  end

  def extra_stubbing
  end

  def stub_billing_facade
    allow(BillingFacadeClient).to receive(:validate_cost_code?).and_return(true)
  end

  def make_rs_response(items)
    result_set = double(:result_set, to_a: items.to_a, has_next?: false)
    return double(:response, result_set: result_set)
  end

  def make_project(id, cost_code)
    proj = double(:project, id: id, name: "project #{id}", cost_code: cost_code)
    allow(StudyClient::Node).to receive(:find).with(id).and_return([proj])
    proj
  end

  def make_set(empty=false, available=true, clone_set=nil)
    uuid = SecureRandom.uuid
    set = double(:set, id: uuid, uuid: uuid, name: "Set #{uuid}", locked: clone_set.nil?)

    if empty
      set_materials = double(:set_materials, materials: [])
    else
      matid = SecureRandom.uuid
      set_content_material = double(:material, id: matid)
      set_materials = double(:set_materials, materials: [set_content_material])
      material = double(:material, id: matid, attributes: { 'available' => available})
      allow(MatconClient::Material).to receive(:where).with("_id" => { "$in" => [matid]}).and_return(make_rs_response([material]))
    end

    allow(SetClient::Set).to receive(:find_with_materials).with(uuid).and_return([set_materials])
    if clone_set
      allow(set).to receive(:create_locked_clone).and_return(clone_set)
    end
    allow(SetClient::Set).to receive(:find).with(uuid).and_return([set])
    set
  end

  def make_plan_with_orders
    plan = create(:work_plan, original_set_uuid: set.uuid, project_id: project.id, product: product)
    module_choices = processes.map { |pro| [pro.process_modules.first.id] }
    wo = plan.create_orders(module_choices, set.id)
    plan.reload
  end

  # Creates two processes for a product. Each process has two modules: one default and one not default.
  def create_processes(prod)
    (0..1).map do |i|
      pro = create(:process, name: "process #{prod.id}-#{i}")
      create(:aker_product_process, product: product, aker_process: pro, stage: i)
      mod = create(:aker_process_module, name: "module #{prod.id}-#{i}", aker_process_id: pro.id)
      create(:aker_process_module_pairings, to_step_id: mod.id, default_path: true, aker_process: pro)
      create(:aker_process_module_pairings, from_step_id: mod.id, default_path: true, aker_process: pro)
      modb = create(:aker_process_module, name: "module #{prod.id}-#{i}B", aker_process_id: pro.id)
      create(:aker_process_module_pairings, to_step_id: modb.id, default_path: false, aker_process: pro)
      create(:aker_process_module_pairings, from_step_id: modb.id, default_path: false, aker_process: pro)
      pro
    end
  end

  describe 'selecting a project' do

    let(:new_project) { make_project(21, 'S1234-2') }

    let(:params) { { project_id: new_project.id } }

    context 'when the plan has no set selected' do
      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /select.*set/
      end
      it 'should not set the project in the plan' do
        expect(plan.project_id).to be_nil
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
    end

    context 'when the plan has a set selected' do
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid) }

      it { expect(@result).to be_truthy }
      it 'should produce no error messages' do
        expect(messages).to be_empty
      end
      it 'should set the project in the plan' do
        expect(plan.project_id).to eq(new_project.id)
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
    end

    context 'when the plan already has a project selected' do
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid, project_id: project.id) }
      it { expect(@result).to be_truthy }
      it 'should produce no error messages' do
        expect(messages).to be_empty
      end
      it 'should set the project in the plan' do
        expect(plan.project_id).to eq(new_project.id)
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
    end

    context 'when the cost code is invalid' do
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid) }
      def stub_billing_facade
        allow(BillingFacadeClient).to receive(:validate_cost_code?).and_return(false)
      end
      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /cost code/
      end
      it 'should not set the project in the plan' do
        expect(plan.project_id).to be_nil
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
    end

    context 'when the project has no cost code' do
      let(:new_project) { make_project(21, nil) }
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid) }

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /cost code/
      end
      it 'should not set the project in the plan' do
        expect(plan.project_id).to be_nil
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
    end

    context 'when the project does not exist' do
      let(:params) do
        id = -100
        allow(StudyClient::Node).to receive(:find).with(id).and_return([])
        { project_id: id }
      end
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid) }

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /project.*found/
      end
      it 'should not set the project in the plan' do
        expect(plan.project_id).to be_nil
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
    end

    context 'when the plan is in progress' do
      let(:plan) do
        plan = make_plan_with_orders
        plan.work_orders.first.update_attributes!(status: 'active')
        plan
      end

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /in progress/
      end
      it 'should not change the project in the plan' do
        expect(plan.project_id).to eq(project.id)
      end
      it 'should still be active' do
        expect(plan).to be_active
      end
    end

  end

  describe 'selecting a set' do
    let(:new_set) { make_set(false, true) }
    let(:params) { { original_set_uuid: new_set.uuid } }

    context 'when the plan has no set selected' do
      it { expect(@result).to be_truthy }
      it 'should produce no error messages' do
        expect(messages).to be_empty
      end
      it 'should set the set in the plan' do
        expect(plan.original_set_uuid).to eq(new_set.uuid)
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
    end

    context 'when the plan is already active' do
      let(:plan) do
        plan = make_plan_with_orders
        plan.work_orders.first.update_attributes!(status: 'active')
        plan
      end

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /in progress/
      end
      it 'should not change the set in the plan' do
        expect(plan.original_set_uuid).to eq(set.uuid)
      end
      it 'should still be active' do
        expect(plan).to be_active
      end
    end
  end

  describe 'selecting a product' do
    let(:product_options) { processes.map { |pro| [pro.process_modules.first.id] } }
    let(:params) do
      {
        product_id: product.id,
        comment: 'commentary',
        desired_date: Date.today,
        product_options: product_options.to_json,
      }
    end

    context 'when the plan does not have a project yet' do
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid) }

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /select.*project/
      end
      it 'should not change the product in the plan' do
        expect(plan.product_id).to be_nil
      end
      it 'should not set the comment' do
        expect(plan.comment).to be_nil
      end
      it 'should not set the date' do
        expect(plan.desired_date).to be_nil
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
      it 'should not have orders' do
        expect(plan.work_orders).to be_empty
      end
    end

    context 'when the plan has a project' do
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid, project_id: project.id) }

      def stub_billing_facade
        super
        allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(15)
      end

      it { expect(@result).to be_truthy }
      it 'should not produce an error message' do
        expect(messages).to be_empty
      end
      it 'should set the product in the plan' do
        expect(plan.product_id).to eq(product.id)
      end
      it 'should set the comment' do
        expect(plan.comment).to eq(params[:comment])
      end
      it 'should set the date' do
        expect(plan.desired_date).to eq(params[:desired_date])
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
      it 'should have created orders' do
        expect(plan.work_orders.length).to eq(processes.length)
      end
      it 'should have correctly set up work orders' do
        plan.work_orders.zip(processes, product_options).each do |order, pro, opts|
          expect(order).to be_queued
          expect(order.process).to eq(pro)
          expect(order.work_order_module_choices.map(&:aker_process_modules_id)).to eq(opts)
        end
      end
      it 'orders should have correct sets' do
        plan.work_orders.each_with_index do |order, i|
          if i==0
            expect(order.original_set_uuid).to eq(plan.original_set_uuid)
            expect(order.set_uuid).to eq(locked_set.uuid)
          else
            expect(order.original_set_uuid).to be_nil
            expect(order.set_uuid).to be_nil
          end
        end
      end
    end

    context 'when the modules and cost code are invalid' do
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid, project_id: project.id) }

      def stub_billing_facade
        super
        allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(nil)
      end

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /modules.*cost code/
      end
      it 'should not set the product in the plan' do
        expect(plan.product_id).to be_nil
      end
      it 'should not set the comment' do
        expect(plan.comment).to be_nil
      end
      it 'should not set the date' do
        expect(plan.desired_date).to be_nil
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
      it 'should not have created orders' do
        expect(plan.work_orders).to be_empty
      end
    end

    context 'when the work orders are already created but not started' do
      let(:old_locked_set) { make_set(false, true) }

      let(:plan) do
        plan = make_plan_with_orders
        @old_order = plan.work_orders.first
        @old_order.update_attributes!(set_uuid: old_locked_set.uuid)
        plan
      end

      # product options different from the defaults
      let(:product_options) do
        processes.map { |pro| [pro.process_modules[1].id] }
      end

      def stub_billing_facade
        super
        allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(15)
      end

      it { expect(@result).to be_truthy }
      it 'should not produce an error message' do
        expect(messages).to be_empty
      end
      it 'should set the product in the plan' do
        expect(plan.product_id).to eq(product.id)
      end
      it 'should set the comment' do
        expect(plan.comment).to eq(params[:comment])
      end
      it 'should set the date' do
        expect(plan.desired_date).to eq(params[:desired_date])
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
      it 'should have created orders' do
        expect(plan.work_orders.length).to eq(processes.length)
      end
      it 'should have correctly set up work orders' do
        plan.work_orders.zip(processes, product_options).each do |order, pro, opts|
          expect(order).to be_queued
          expect(order.process).to eq(pro)
          expect(order.work_order_module_choices.map(&:aker_process_modules_id)).to eq(opts)
        end
      end
      it 'should have destroyed old orders' do
        expect(WorkOrder.where(id: @old_order.id)).to be_empty
      end
      it 'orders should have correct sets' do
        plan.work_orders.each_with_index do |order, i|
          if i==0
            expect(order.original_set_uuid).to eq(plan.original_set_uuid)
            expect(order.set_uuid).to eq(old_locked_set.uuid)
          else
            expect(order.original_set_uuid).to be_nil
            expect(order.set_uuid).to be_nil
          end
        end
      end
    end

    context 'when an order has already been dispatched' do
      let(:plan) do
        plan = make_plan_with_orders
        @old_order = plan.work_orders.first
        @old_order.update_attributes!(status: 'active')
        plan
      end

      # product options different from the defaults
      let(:product_options) do
        processes.map { |pro| [pro.process_modules[1].id] }
      end

      def stub_billing_facade
        super
        allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(15)
      end

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /in progress/
      end
      it 'should not set the comment' do
        expect(plan.comment).to be_nil
      end
      it 'should not set the date' do
        expect(plan.desired_date).to be_nil
      end
      it 'should still be active' do
        expect(plan).to be_active
      end
      it 'should still have orders' do
        expect(plan.work_orders.length).to eq(processes.length)
      end
      it 'should have the same orders as before' do
        expect(plan.work_orders.first).to eq(@old_order)
      end
    end

    context 'when no product options are supplied' do
      let(:plan) { create(:work_plan, original_set_uuid: set.uuid, project_id: project.id) }
      let(:params) do
        {
          product_id: product.id,
          comment: 'commentary',
          desired_date: Date.today,
        }
      end

      def stub_billing_facade
        super
        allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(15)
      end

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /invalid/i
      end
      it 'should not set the product in the plan' do
        expect(plan.product_id).to be_nil
      end
      it 'should not set the comment' do
        expect(plan.comment).to be_nil
      end
      it 'should not set the date' do
        expect(plan.desired_date).to be_nil
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
      it 'should not have orders' do
        expect(plan.work_orders).to be_empty
      end
    end

    context 'when no product id is supplied' do

      let(:plan) { create(:work_plan, original_set_uuid: set.uuid, project_id: project.id) }
      let(:params) do
        {
          comment: 'commentary',
          desired_date: Date.today,
          product_options: product_options.to_json,
        }
      end

      def stub_billing_facade
        super
        allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(15)
      end

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /invalid/i
      end
      it 'should not set the product in the plan' do
        expect(plan.product_id).to be_nil
      end
      it 'should not set the comment' do
        expect(plan.comment).to be_nil
      end
      it 'should not set the date' do
        expect(plan.desired_date).to be_nil
      end
      it 'should still be in construction' do
        expect(plan).to be_in_construction
      end
      it 'should not have orders' do
        expect(plan.work_orders).to be_empty
      end
    end
  end

  describe 'altering product modules' do
    let(:plan) do
      plan = make_plan_with_orders
      plan.work_orders.first.update_attributes!(status: 'active')
      plan
    end

    let(:old_orders) {
      plan.work_orders.to_a
    }

    let(:params) do
      {
        work_order_id: old_orders[1].id,
        work_order_modules: [processes[1].process_modules[1].id].to_json,
      }
    end

    let(:module_cost) { 15 }

    def stub_billing_facade
      super
      allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(module_cost)
    end

    context 'when the order is queued' do
      it { expect(@result).to be_truthy }
      it 'should not produce an error message' do
        expect(messages).to be_empty
      end
      it 'should still be active' do
        expect(plan).to be_active
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(old_orders)
      end
      it 'should have correctly set the modules for the orders' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[1].id])
      end
    end

    context 'when the order is active' do
      let(:params) do
        {
          work_order_id: old_orders[0].id,
          work_order_modules: [processes[0].process_modules[1].id].to_json,
        }
      end
      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /order.*cannot.*update/i
      end
      it 'should still be active' do
        expect(plan).to be_active
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(old_orders)
      end
      it 'should still have the original modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
    end

    context 'when the modules cannot be costed' do
      let(:module_cost) { nil }

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /module/i
      end
      it 'should still be active' do
        expect(plan).to be_active
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(old_orders)
      end
      it 'should still have the original modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
    end
  end

  describe 'dispatching the first order' do
    let(:plan) { make_plan_with_orders }
    let(:orders) { plan.work_orders }
    let(:params) do
      {
        work_order_id: orders[0].id,
        work_order_modules: [processes[0].process_modules[1].id].to_json,
      }
    end
    let(:dispatch) { true }

    def stub_billing_facade
      super
      allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(13)
    end

    def extra_stubbing
      @sent_to_lims = false
      @sent_event = false
      allow_any_instance_of(WorkOrder).to receive(:send_to_lims) { @sent_to_lims = true }
      allow_any_instance_of(WorkOrder).to receive(:generate_submitted_event) { @sent_event = true }
    end

    context 'when the order is queued' do
      it { expect(@result).to be_truthy }
      it 'should not produce an error message' do
        expect(messages).to be_empty
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(orders)
      end
      it 'should have orders with the correct modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[1].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
      it 'should be active' do
        expect(plan.reload).to be_active
      end
      it 'should have sent the order' do
        expect(@sent_to_lims).to eq(true)
      end
      it 'should have generated an event' do
        expect(@sent_event).to eq(true)
      end
      it 'should have made the order active' do
        expect(orders[0].reload).to be_active
      end
      it 'should have a dispatch date' do
        expect(orders[0].reload.dispatch_date).not_to be_nil
      end
    end

    context 'when the order is active' do
      let(:old_date) { Date.yesterday }
      let(:plan) do
        plan = make_plan_with_orders
        plan.work_orders[0].update_attributes(status: 'active', dispatch_date: old_date)
        plan
      end

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /cannot.*dispatch/i
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(orders)
      end
      it 'should not have changed the order modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
      it 'should still be active' do
        expect(plan.reload).to be_active
      end
      it 'should not have sent the order' do
        expect(@sent_to_lims).to eq(false)
      end
      it 'should not have generated an event' do
        expect(@sent_event).to eq(false)
      end
      it 'should not have changed the order status' do
        expect(orders[0].reload).to be_active
      end
      it 'should not have changed the dispatch date' do
        expect(orders[0].reload.dispatch_date).to eq(old_date)
      end
    end

    context 'when the set is empty' do
      let(:set) { make_set(true, true, locked_set) }

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /set.*empty/i
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(orders)
      end
      it 'should not have changed the order modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
      it 'should still be in construction' do
        expect(plan.reload).to be_in_construction
      end
      it 'should not have sent the order' do
        expect(@sent_to_lims).to eq(false)
      end
      it 'should not have generated an event' do
        expect(@sent_event).to eq(false)
      end
      it 'should not have changed the order status' do
        expect(orders[0].reload).to be_queued
      end
      it 'should not have changed the dispatch date' do
        expect(orders[0].reload.dispatch_date).to be_nil
      end
    end

    context 'when the set materials are unavailable' do
      let(:set) { make_set(false, false, locked_set) }

      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to match /material.*available/i
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(orders)
      end
      it 'should not have changed the order modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
      it 'should still be in construction' do
        expect(plan.reload).to be_in_construction
      end
      it 'should not have sent the order' do
        expect(@sent_to_lims).to eq(false)
      end
      it 'should not have generated an event' do
        expect(@sent_event).to eq(false)
      end
      it 'should not have changed the order status' do
        expect(orders[0].reload).to be_queued
      end
      it 'should not have changed the dispatch date' do
        expect(orders[0].reload.dispatch_date).to be_nil
      end
    end
  end

  describe 'dispatching a subsequent order' do

    let(:orders) { plan.work_orders }
    let(:params) do
      {
        work_order_id: orders[1].id,
        work_order_modules: [processes[1].process_modules[1].id].to_json,
      }
    end
    let(:dispatch) { true }

    def stub_billing_facade
      super
      allow(BillingFacadeClient).to receive(:get_cost_information_for_module).and_return(13)
    end

    def extra_stubbing
      @sent_to_lims = false
      @sent_event = false
      allow_any_instance_of(WorkOrder).to receive(:send_to_lims) { @sent_to_lims = true }
      allow_any_instance_of(WorkOrder).to receive(:generate_submitted_event) { @sent_event = true }
    end

    context 'when the first order is queued' do
      let(:plan) { make_plan_with_orders }
      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to be_present
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(orders)
      end
      it 'should not have changed the order modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
      it 'should still be in construction' do
        expect(plan.reload).to be_in_construction
      end
      it 'should not have sent the order' do
        expect(@sent_to_lims).to eq(false)
      end
      it 'should not have generated an event' do
        expect(@sent_event).to eq(false)
      end
      it 'should not have changed the order status' do
        expect(orders[1].reload).to be_queued
      end
      it 'should not have changed the dispatch date' do
        expect(orders[1].reload.dispatch_date).to be_nil
      end
    end

    context 'when the first order is active' do
      let(:plan) do
        plan = make_plan_with_orders
        plan.work_orders.first.update_attributes!(status: 'active')
        plan
      end
      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to be_present
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(orders)
      end
      it 'should not have changed the order modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
      it 'should still be active' do
        expect(plan.reload).to be_active
      end
      it 'should not have sent the order' do
        expect(@sent_to_lims).to eq(false)
      end
      it 'should not have generated an event' do
        expect(@sent_event).to eq(false)
      end
      it 'should not have changed the order status' do
        expect(orders[1].reload).to be_queued
      end
      it 'should not have changed the dispatch date' do
        expect(orders[1].reload.dispatch_date).to be_nil
      end
    end

    context 'when the order is already active' do
      let(:plan) do
        plan = make_plan_with_orders
        plan.work_orders.first.update_attributes!(status: 'completed', finished_set_uuid: locked_set.uuid)
        plan.work_orders[1].update_attributes!(status: 'active')
        plan
      end
      it { expect(@result).to be_falsey }
      it 'should produce an error message' do
        expect(messages[:error]).to be_present
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(orders)
      end
      it 'should not have changed the order modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[0].id])
      end
      it 'should still be active' do
        expect(plan.reload).to be_active
      end
      it 'should not have sent the order' do
        expect(@sent_to_lims).to eq(false)
      end
      it 'should not have generated an event' do
        expect(@sent_event).to eq(false)
      end
      it 'should not have changed the order status' do
        expect(orders[1].reload).to be_active
      end
      it 'should not have changed the dispatch date' do
        expect(orders[1].reload.dispatch_date).to be_nil
      end
    end

    context 'when the order is ready to be dispatched' do
      let(:plan) do
        plan = make_plan_with_orders
        plan.work_orders.first.update_attributes!(status: 'completed', finished_set_uuid: locked_set.uuid)
        plan
      end
      it { expect(@result).to be_truthy }
      it 'should not produce an error message' do
        expect(messages).to be_empty
      end
      it 'should have the same work orders' do
        expect(plan.work_orders.reload).to eq(orders)
      end
      it 'should have updated the order modules' do
        orders = plan.work_orders.reload
        modules = orders.map do |order|
          WorkOrderModuleChoice.where(work_order_id: order.id).map(&:aker_process_modules_id)
        end
        expect(modules[0]).to eq([processes[0].process_modules[0].id])
        expect(modules[1]).to eq([processes[1].process_modules[1].id])
      end
      it 'should be active' do
        expect(plan.reload).to be_active
      end
      it 'should have sent the order' do
        expect(@sent_to_lims).to eq(true)
      end
      it 'should have generated an event' do
        expect(@sent_event).to eq(true)
      end
      it 'should have changed the order status' do
        expect(orders[1].reload).to be_active
      end
      it 'should have changed the dispatch date' do
        expect(orders[1].reload.dispatch_date).not_to be_nil
      end
      
    end
  end
end













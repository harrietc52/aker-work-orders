class OrdersController < ApplicationController

  include Wicked::Wizard
  steps :product, :details, :set, :summary

  def show
    render_wizard
  end

  def update
    params[:work_order][:status] = step.to_s
    params[:work_order][:status] = 'active' if last_step?

    if work_order.update_attributes(work_order_params) && last_step?
      flash[:notice] = 'Your Work Order has been created'
    end

    render_wizard work_order
  end

  protected

  def work_order
    @work_order ||= WorkOrder.find(params[:work_order_id])
  end

  def item
    work_order.item || Item.new
  end

  def item_option_selections
    item.item_option_selections
  end

  def last_step?
    step == steps.last
  end

  def first_step?
    step == steps.first
  end

  helper_method :work_order, :item, :item_option_selections, :last_step?, :first_step?

  private

  def work_order_params
    params.require(:work_order).permit(
      :status, item_attributes: [
        :id, :product_id, item_option_selections_attributes: [
          :id, :product_option_id, :product_option_value_id
        ]
      ]
    )
  end

end

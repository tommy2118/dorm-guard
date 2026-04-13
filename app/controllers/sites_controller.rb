class SitesController < ApplicationController
  before_action :set_site, only: [ :show ]

  def index
    @sites = Site.order(:name)
  end

  def show
    @pagy, @check_results = pagy(@site.check_results.order(checked_at: :desc))
  end

  private

  def set_site
    @site = Site.find(params[:id])
  end
end

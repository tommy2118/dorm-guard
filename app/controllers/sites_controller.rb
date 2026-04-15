class SitesController < ApplicationController
  before_action :set_site, only: [ :show, :edit, :update, :destroy ]

  def index
    @pagy, @sites = pagy(Site.order(:name))
  end

  def show
    @pagy, @check_results = pagy(@site.check_results.order(checked_at: :desc))
  end

  def new
    @site = Site.new
  end

  def create
    @site = Site.new(site_params)

    if @site.save
      redirect_to sites_path, notice: "Site created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @site.update(site_params)
      redirect_to sites_path, notice: "Site updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @site.destroy!
    redirect_to sites_path, notice: "Site deleted."
  end

  private

  def set_site
    @site = Site.find(params[:id])
  end

  def site_params
    params.expect(site: [
      :name, :url, :interval_seconds, :check_type,
      :tls_port, :tcp_port, :dns_hostname, :content_match_pattern,
      :follow_redirects, :expected_status_codes, :slow_threshold_ms
    ])
  end
end

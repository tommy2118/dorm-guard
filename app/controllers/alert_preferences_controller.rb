class AlertPreferencesController < ApplicationController
  before_action :set_site
  before_action :set_alert_preference, only: [ :edit, :update, :destroy ]

  def index
    @alert_preferences = @site.alert_preferences.order(:channel, :created_at)
  end

  def new
    @alert_preference = @site.alert_preferences.new
  end

  def create
    @alert_preference = @site.alert_preferences.new(alert_preference_params)

    if @alert_preference.save
      redirect_to site_alert_preferences_path(@site), notice: "Alert preference created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @alert_preference.update(alert_preference_params)
      redirect_to site_alert_preferences_path(@site), notice: "Alert preference updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @alert_preference.destroy!
    redirect_to site_alert_preferences_path(@site), notice: "Alert preference deleted."
  end

  private

  def set_site
    @site = Site.find(params[:site_id])
  end

  # Scope lookup through the site association so a route like
  # /sites/1/alert_preferences/<id-from-site-2> returns 404 rather than
  # exposing cross-site records.
  def set_alert_preference
    @alert_preference = @site.alert_preferences.find(params[:id])
  end

  def alert_preference_params
    params.expect(alert_preference: [
      :channel, :target, :enabled, { events: [] }
    ])
  end
end

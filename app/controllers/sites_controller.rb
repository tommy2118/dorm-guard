class SitesController < ApplicationController
  def index
    @sites = Site.order(:name)
  end
end

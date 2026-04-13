class SiteDetailComponent < ApplicationComponent
  def initialize(site:)
    @site = site
  end

  attr_reader :site

  def last_checked_label
    return "Never" if site.last_checked_at.nil?

    "#{helpers.time_ago_in_words(site.last_checked_at)} ago"
  end
end

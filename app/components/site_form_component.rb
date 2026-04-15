class SiteFormComponent < ApplicationComponent
  CHECK_TYPE_LABELS = {
    "http" => "HTTP",
    "ssl" => "SSL certificate expiry",
    "tcp" => "TCP port",
    "dns" => "DNS resolution",
    "content_match" => "HTTP content match"
  }.freeze

  def initialize(site:)
    @site = site
  end

  attr_reader :site

  def submit_label
    site.persisted? ? "Update site" : "Create site"
  end

  def heading
    site.persisted? ? "Edit site" : "New site"
  end

  def field_error(attribute)
    messages = site.errors[attribute]
    messages.first if messages.any?
  end

  def check_type_options
    CHECK_TYPE_LABELS.map { |value, label| [ label, value ] }
  end

  # Emit the IANA identifier (e.g., "America/New_York") as the option VALUE,
  # matching what Site#normalizes persists. Keep Rails' formatted label
  # ("(GMT-05:00) Eastern Time (US & Canada)") as the display. Without this
  # alignment, a site persisted with "America/New_York" would render the
  # select with no matching option and a silent save would wipe the tz.
  def timezone_options
    ActiveSupport::TimeZone.all.map { |tz| [ tz.to_s, tz.tzinfo.name ] }
  end
end

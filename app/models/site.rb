class Site < ApplicationRecord
  MIN_INTERVAL_SECONDS = 30
  DEFAULT_TLS_PORT = 443
  DEFAULT_TCP_PORT = 80
  CONTENT_MATCH_PATTERN_MAX = 500
  HTTP_STATUS_RANGE = 100..599
  SLOW_THRESHOLD_RANGE = 100..60_000

  DNS_HOSTNAME_REGEX = /\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\z/i

  # Integer 3 is intentionally skipped. :degraded is appended at 4 so
  # :down stays at 2 and existing stored values never need to renumber.
  enum :status, { unknown: 0, up: 1, down: 2, degraded: 4 }, default: :unknown
  # candidate_status reuses the same integer mapping as status; the :candidate_ prefix
  # avoids the predicate collision that Rails' enum would generate on raw aliasing.
  enum :candidate_status, { unknown: 0, up: 1, down: 2, degraded: 4 }, prefix: :candidate, allow_nil: true
  enum :check_type, { http: 0, ssl: 1, tcp: 2, dns: 3, content_match: 4 }, default: :http

  serialize :expected_status_codes, coder: JSON
  serialize :last_alerted_events, coder: JSON, type: Hash

  # Canonicalize quiet_hours_timezone to its IANA identifier on assignment
  # so the DB, form options, specs, and seeds all speak the same dialect.
  # Accepts any input ActiveSupport::TimeZone recognizes (IANA identifier,
  # Rails friendly name, or nil) and always stores the IANA form — that's
  # what SiteFormComponent#timezone_options emits, so the edit form's
  # <select> always finds the persisted value and marks it selected.
  # Invalid inputs pass through unchanged so validate_quiet_hours_timezone
  # can reject them with a proper error.
  normalizes :quiet_hours_timezone, with: ->(value) do
    return nil if value.blank?

    zone = ActiveSupport::TimeZone[value.to_s.strip]
    zone ? zone.tzinfo.name : value
  end

  has_many :check_results, dependent: :destroy
  has_many :alert_preferences, dependent: :destroy

  before_validation :clear_irrelevant_config

  validates :name, presence: true
  validates :url,
            presence: true,
            format: {
              with: URI::DEFAULT_PARSER.make_regexp(%w[http https]),
              allow_blank: true
            },
            unless: :dns?
  validates :interval_seconds,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: MIN_INTERVAL_SECONDS }
  validates :tls_port,
            presence: true,
            numericality: { only_integer: true, in: 1..65_535 },
            if: :ssl?
  validates :tcp_port,
            presence: true,
            numericality: { only_integer: true, in: 1..65_535 },
            if: :tcp?
  validates :dns_hostname,
            presence: true,
            format: { with: DNS_HOSTNAME_REGEX },
            length: { maximum: 253 },
            if: :dns?
  validates :content_match_pattern,
            presence: true,
            length: { maximum: CONTENT_MATCH_PATTERN_MAX },
            if: :content_match?
  validates :slow_threshold_ms,
            numericality: { only_integer: true, in: SLOW_THRESHOLD_RANGE },
            allow_nil: true
  validates :cooldown_minutes,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  validate :validate_expected_status_codes
  validate :validate_quiet_hours_pair
  validate :validate_quiet_hours_timezone

  # Accepts either an array (round-tripped from the DB) or a string typed
  # into the form (e.g., "200, 301"). Parses strings into an integer array;
  # invalid tokens trip an instance variable that the validator converts
  # to a user-visible error. Empty/blank strings are stored as nil.
  def expected_status_codes=(value)
    @expected_status_codes_parse_error = nil
    super(parse_expected_status_codes(value))
  end

  # Form redisplay: when parsing fails, the setter stores nil in the
  # attribute and stashes the raw bad input in an instance var. Return
  # that raw value so the user sees their original text back (with the
  # validation error) instead of an empty field that wiped their typing.
  def expected_status_codes_for_display
    return @expected_status_codes_parse_error.to_s if @expected_status_codes_parse_error

    expected_status_codes.is_a?(Array) ? expected_status_codes.join(", ") : ""
  end

  def due?
    last_checked_at.nil? || last_checked_at <= interval_seconds.seconds.ago
  end

  def healthy?
    up?
  end

  def failing?
    down?
  end

  def alert_cooldown_expired?(event, now = Time.current)
    events_hash = last_alerted_events || {}
    last = events_hash[event.to_s]
    return true if last.blank?

    parsed = Time.zone.parse(last.to_s)
    return true if parsed.nil?

    parsed + cooldown_minutes.minutes <= now
  end

  def record_alert_sent!(event, now = Time.current)
    merged = (last_alerted_events || {}).merge(event.to_s => now.iso8601)
    update!(last_alerted_events: merged)
  end

  # N=2 consecutive-check debounce. Mutates self in memory only; the caller
  # (PerformCheckJob#update_site) owns persistence and decides which attributes
  # to save. Does not touch updated_at (no save here). Returns the proposed
  # effective status as a string so the caller can diff against the
  # pre-proposal value.
  #
  # Rules (new_status is the status derived from the latest check):
  #   - new_status matches the confirmed status → clear candidate, no change
  #   - new_status matches the pending candidate → commit the new status
  #   - new_status differs from both → pending candidate is replaced
  def propose_status(new_status, now = Time.current)
    new_status_str = new_status.to_s

    if new_status_str == status
      self.candidate_status = nil
      self.candidate_status_at = nil
    elsif new_status_str == candidate_status
      self.status = new_status_str
      self.candidate_status = nil
      self.candidate_status_at = nil
    else
      self.candidate_status = new_status_str
      self.candidate_status_at = now
    end

    status
  end

  def in_quiet_hours?(now = Time.current)
    return false if quiet_hours_start.blank? || quiet_hours_end.blank?

    zone = resolved_quiet_hours_zone
    local_now = now.in_time_zone(zone)
    current_seconds = local_now.seconds_since_midnight.to_i
    start_seconds = seconds_since_midnight(quiet_hours_start)
    end_seconds = seconds_since_midnight(quiet_hours_end)

    if start_seconds <= end_seconds
      current_seconds >= start_seconds && current_seconds < end_seconds
    else
      current_seconds >= start_seconds || current_seconds < end_seconds
    end
  end

  private

  def resolved_quiet_hours_zone
    name = quiet_hours_timezone.presence || Rails.application.config.time_zone
    ActiveSupport::TimeZone[name] || ActiveSupport::TimeZone["UTC"]
  end

  def seconds_since_midnight(time_value)
    return 0 if time_value.nil?

    time_value.hour * 3600 + time_value.min * 60 + time_value.sec
  end

  def validate_quiet_hours_pair
    return if quiet_hours_start.nil? && quiet_hours_end.nil?
    return if quiet_hours_start.present? && quiet_hours_end.present?

    errors.add(:quiet_hours_end, "must be set together with quiet_hours_start")
  end

  def validate_quiet_hours_timezone
    return if quiet_hours_timezone.blank?
    return if ActiveSupport::TimeZone[quiet_hours_timezone]

    errors.add(:quiet_hours_timezone, "is not a recognized ActiveSupport::TimeZone name")
  end


  def parse_expected_status_codes(value)
    return nil if value.nil?
    return value if value.is_a?(Array)

    str = value.to_s.strip
    return nil if str.empty?

    tokens = str.split(",").map(&:strip).reject(&:empty?)
    tokens.map { |t| Integer(t, 10) }
  rescue ArgumentError
    @expected_status_codes_parse_error = value
    nil
  end

  def validate_expected_status_codes
    if @expected_status_codes_parse_error
      errors.add(:expected_status_codes, "must be comma-separated integers in 100-599 (e.g., 200,301)")
      return
    end
    return if expected_status_codes.nil?

    expected_status_codes.each do |code|
      unless code.is_a?(Integer) && HTTP_STATUS_RANGE.cover?(code)
        errors.add(:expected_status_codes, "must be integers in 100-599")
        return
      end
    end
  end

  def clear_irrelevant_config
    self.tls_port = nil unless ssl?
    self.tcp_port = nil unless tcp?
    self.dns_hostname = nil unless dns?
    self.content_match_pattern = nil unless content_match?
    self.slow_threshold_ms = nil unless http? || content_match?
    self.expected_status_codes = nil unless http? || content_match?
    # follow_redirects is boolean + null: false, so we can't null it.
    # Reset to the DB default (true) on non-HTTP flips so the row doesn't
    # carry a stale "false" value from a previous :http config.
    self.follow_redirects = true unless http? || content_match?
    self.url = nil if dns?
  end
end

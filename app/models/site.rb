class Site < ApplicationRecord
  MIN_INTERVAL_SECONDS = 30
  DEFAULT_TLS_PORT = 443
  DEFAULT_TCP_PORT = 80
  CONTENT_MATCH_PATTERN_MAX = 500
  HTTP_STATUS_RANGE = 100..599

  DNS_HOSTNAME_REGEX = /\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\z/i

  enum :status, { unknown: 0, up: 1, down: 2 }, default: :unknown
  enum :check_type, { http: 0, ssl: 1, tcp: 2, dns: 3, content_match: 4 }, default: :http

  serialize :expected_status_codes, coder: JSON

  has_many :check_results, dependent: :destroy

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

  validate :validate_expected_status_codes

  # Accepts either an array (round-tripped from the DB) or a string typed
  # into the form (e.g., "200, 301"). Parses strings into an integer array;
  # invalid tokens trip an instance variable that the validator converts
  # to a user-visible error. Empty/blank strings are stored as nil.
  def expected_status_codes=(value)
    @expected_status_codes_parse_error = nil
    super(parse_expected_status_codes(value))
  end

  def expected_status_codes_for_display
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

  private

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
    self.url = nil if dns?
  end
end

class Site < ApplicationRecord
  MIN_INTERVAL_SECONDS = 30
  DEFAULT_TLS_PORT = 443

  enum :status, { unknown: 0, up: 1, down: 2 }, default: :unknown
  enum :check_type, { http: 0, ssl: 1, tcp: 2, dns: 3, content_match: 4 }, default: :http

  has_many :check_results, dependent: :destroy

  before_validation :clear_irrelevant_config

  validates :name, presence: true
  validates :url, presence: true, format: {
    with: URI::DEFAULT_PARSER.make_regexp(%w[http https]),
    allow_blank: true
  }
  validates :interval_seconds,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: MIN_INTERVAL_SECONDS }
  validates :tls_port,
            presence: true,
            numericality: { only_integer: true, in: 1..65_535 },
            if: :ssl?

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

  # Seam for per-check-type config scrubbing. Later slices extend this as new
  # columns land. Keeps the schema honest: a flipped check_type never leaves
  # stale config from the old type hanging around.
  def clear_irrelevant_config
    self.tls_port = nil unless ssl?
  end
end

class Site < ApplicationRecord
  MIN_INTERVAL_SECONDS = 30

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

  # Seam for per-check-type config scrubbing. Later slices extend this to null
  # out columns that don't apply to the current check_type (e.g., tcp_port
  # when check_type flips to :http). No-op in this slice — the scaffold is
  # intentional so the callback wiring ships once and later slices only add
  # field-scrubbing lines.
  def clear_irrelevant_config
    # intentionally empty — populated by later slices as new columns land
  end
end

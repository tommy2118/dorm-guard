class Site < ApplicationRecord
  MIN_INTERVAL_SECONDS = 30

  enum :status, { unknown: 0, up: 1, down: 2 }, default: :unknown

  has_many :check_results, dependent: :destroy

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
end

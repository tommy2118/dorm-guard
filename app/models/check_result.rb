class CheckResult < ApplicationRecord
  belongs_to :site

  validates :checked_at, presence: true
  validates :response_time_ms, presence: true
end

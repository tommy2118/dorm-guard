class AlertPreference < ApplicationRecord
  EVENTS = %w[down up degraded].freeze

  belongs_to :site

  enum :channel, { email: 0, slack: 1, webhook: 2 }

  serialize :events, coder: JSON, type: Array

  normalizes :target, with: ->(value) { value.to_s.strip }

  before_validation :normalize_events

  validates :channel, presence: true
  validates :target, presence: true
  validate :validate_events
  validate :validate_target

  private

  def normalize_events
    self.events = Array(events).map { |e| e.to_s.strip }.reject(&:blank?).uniq
  end

  def validate_events
    if events.blank?
      errors.add(:events, "must include at least one event")
      return
    end

    invalid = events - EVENTS
    return if invalid.empty?

    errors.add(:events, "contains unsupported values: #{invalid.join(', ')}")
  end

  def validate_target
    return if target.blank?

    if email?
      validate_email_target
    else
      validate_https_url_target
    end
  end

  def validate_email_target
    return if URI::MailTo::EMAIL_REGEXP.match?(target)

    errors.add(:target, "is not a valid email address")
  end

  def validate_https_url_target
    uri = URI.parse(target)
  rescue URI::InvalidURIError
    errors.add(:target, "is not a valid URL")
  else
    if uri.scheme != "https"
      errors.add(:target, "must use the https scheme")
    elsif uri.host.blank?
      errors.add(:target, "must include a host")
    elsif uri.userinfo.present?
      errors.add(:target, "must not include userinfo (user:password@)")
    end
  end
end

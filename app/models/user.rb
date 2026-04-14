class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  # has_secure_password validates presence and max length (72 chars) but not minimum.
  # allow_nil: true so updating other attributes (e.g. email_address) on an existing
  # record does not trigger this validation when password is not being changed.
  validates :password, length: { minimum: 16 }, allow_nil: true
end

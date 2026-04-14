# Seeds are split into two concerns:
#
#  - Dev fixtures (32 sites) populate only when Rails.env.development?
#    so that `bin/dc bin/rails db:seed` on a local machine gives you a
#    realistic pagination table immediately. These never run in
#    production because Rails 8's `db:prepare` (invoked by the
#    container entrypoint on fresh boot) evaluates this file in
#    RAILS_ENV=production where the guard below is false.
#
#  - Smoke-test sites (2 sites) populate when ENV["SMOKE_SEED"] is
#    set in any environment. This is how Slice 7's end-to-end smoke
#    proves the deployed scheduler + SMTP path end-to-end:
#        bin/dc kamal app exec "SMOKE_SEED=1 bin/rails db:seed"
#
# The two smoke sites are chosen to fail predictably from an external
# vantage without pointing at loopback or any private range. See the
# memory file feedback_no_loopback_in_prod_seeds for the rationale.

if Rails.env.production?
  # Create-only. Subsequent password changes go through the password reset flow.
  # To rotate password via console: User.find_by(email_address: ENV["ADMIN_EMAIL"])
  #   &.update!(password: ENV["ADMIN_PASSWORD"])
  User.find_or_create_by!(email_address: ENV.fetch("ADMIN_EMAIL")) do |u|
    u.password = ENV.fetch("ADMIN_PASSWORD")
  end
  puts "Admin user seeded."
end

if Rails.env.development?
  Site.find_or_create_by!(name: "Example (always up)") do |site|
    site.url = "https://example.com"
    site.interval_seconds = 60
  end

  Site.find_or_create_by!(name: "Example 404 (always down)") do |site|
    site.url = "https://example.com/definitely-not-a-real-page"
    site.interval_seconds = 60
  end

  # Extra seeds exist so the manual smoke test exercises index pagination
  # (Pagy default limit: 25). Each site points at a distinct example.com
  # subpath so it looks realistic in the table.
  30.times do |i|
    number = format("%02d", i + 1)
    Site.find_or_create_by!(name: "Fixture #{number}") do |site|
      site.url = "https://example.com/sample-#{number}"
      site.interval_seconds = 60
    end
  end

  puts "Seeded #{Site.count} dev fixture sites."
end

if ENV["SMOKE_SEED"]
  # Guaranteed up: IANA-reserved example.com always responds 200/301.
  Site.find_or_create_by!(name: "Smoke (example.com, up)") do |site|
    site.url = "https://example.com"
    site.interval_seconds = 60
  end

  # Guaranteed down: 192.0.2.0/24 is TEST-NET-1 (RFC 5737), reserved
  # for documentation and never routable on the public internet. The
  # connect times out cleanly — from an external vantage it is
  # unambiguously "an external host that doesn't exist", which is
  # exactly what the smoke test needs. NOT loopback/localhost/private
  # ranges, which would muddy the SSRF story deferred to Epic 4.
  Site.find_or_create_by!(name: "Smoke (TEST-NET-1, down)") do |site|
    site.url = "https://192.0.2.1/"
    site.interval_seconds = 60
  end

  puts "Seeded SMOKE_SEED sites."
end

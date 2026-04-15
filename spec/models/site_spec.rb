require "rails_helper"

RSpec.describe Site, type: :model do
  let(:valid_attrs) do
    {
      name: "Example",
      url: "https://example.com",
      interval_seconds: 60
    }
  end

  describe "validations" do
    it "is valid with all required attributes" do
      expect(described_class.new(valid_attrs)).to be_valid
    end

    it "requires a name" do
      site = described_class.new(valid_attrs.merge(name: nil))
      expect(site).not_to be_valid
      expect(site.errors[:name]).to be_present
    end

    it "requires a url" do
      site = described_class.new(valid_attrs.merge(url: nil))
      expect(site).not_to be_valid
      expect(site.errors[:url]).to be_present
    end

    it "rejects a url without an http or https scheme" do
      site = described_class.new(valid_attrs.merge(url: "example.com"))
      expect(site).not_to be_valid
      expect(site.errors[:url]).to be_present
    end

    # Regression lock: pin injection schemes against the http/https whitelist.
    # URI::DEFAULT_PARSER.make_regexp(%w[http https]) rejects all of these;
    # this spec ensures a future refactor cannot silently widen the allowlist.
    %w[javascript:alert(1) data:text/html,<h1>x</h1> file:///etc/passwd ftp://x.com].each do |bad_url|
      it "rejects #{bad_url.split(':').first}: scheme" do
        expect(described_class.new(valid_attrs.merge(url: bad_url))).not_to be_valid
      end
    end

    it "accepts both http and https urls" do
      expect(described_class.new(valid_attrs.merge(url: "http://example.com"))).to be_valid
      expect(described_class.new(valid_attrs.merge(url: "https://example.com"))).to be_valid
    end

    it "requires an interval_seconds" do
      site = described_class.new(valid_attrs.merge(interval_seconds: nil))
      expect(site).not_to be_valid
      expect(site.errors[:interval_seconds]).to be_present
    end

    it "rejects an interval_seconds below the 30 second floor" do
      site = described_class.new(valid_attrs.merge(interval_seconds: 29))
      expect(site).not_to be_valid
      expect(site.errors[:interval_seconds]).to be_present
    end

    it "accepts the exact 30 second floor" do
      expect(described_class.new(valid_attrs.merge(interval_seconds: 30))).to be_valid
    end
  end

  describe "status enum" do
    it "defaults to unknown" do
      expect(described_class.new(valid_attrs).status).to eq("unknown")
    end

    it "supports up, down, and degraded transitions via the enum" do
      site = described_class.new(valid_attrs)

      site.status = :up
      expect(site).to be_up

      site.status = :down
      expect(site).to be_down

      site.status = :degraded
      expect(site).to be_degraded
    end

    it "persists :degraded at integer 4 so :down stays at 2" do
      site = described_class.create!(valid_attrs.merge(status: :degraded))
      expect(site.read_attribute_before_type_cast(:status)).to eq(4)
    end
  end

  describe "check_results association" do
    let(:site) { described_class.create!(valid_attrs) }

    it "starts with no check results" do
      expect(site.check_results).to be_empty
    end

    it "lets check results be associated via the reverse side" do
      result = site.check_results.create!(
        status_code: 200,
        response_time_ms: 123,
        checked_at: Time.current
      )
      expect(site.reload.check_results).to contain_exactly(result)
    end

    it "cascade-deletes check results when the site is destroyed" do
      site.check_results.create!(
        status_code: 200,
        response_time_ms: 123,
        checked_at: Time.current
      )
      expect { site.destroy }.to change(CheckResult, :count).from(1).to(0)
    end
  end

  describe "check_type enum" do
    it "defaults to http" do
      expect(described_class.new(valid_attrs).check_type).to eq("http")
    end

    it "accepts all declared check types" do
      %w[http ssl tcp dns content_match].each do |type|
        site = described_class.new(valid_attrs.merge(check_type: type))
        expect(site.check_type).to eq(type)
      end
    end

    it "exposes predicate methods for each type" do
      site = described_class.new(valid_attrs)
      expect(site).to be_http
      expect(site).not_to be_ssl
    end
  end

  describe "health predicates" do
    let(:site) { described_class.new(valid_attrs) }

    it "is healthy when up" do
      site.status = :up
      expect(site).to be_healthy
      expect(site).not_to be_failing
    end

    it "is failing when down" do
      site.status = :down
      expect(site).to be_failing
      expect(site).not_to be_healthy
    end

    it "is neither healthy nor failing when degraded (it's a warning state)" do
      site.status = :degraded
      expect(site).not_to be_healthy
      expect(site).not_to be_failing
      expect(site).to be_degraded
    end

    it "is neither healthy nor failing when unknown" do
      expect(site).not_to be_healthy
      expect(site).not_to be_failing
    end
  end

  describe "slow_threshold_ms validation" do
    it "is valid when nil (no threshold)" do
      expect(described_class.new(valid_attrs.merge(slow_threshold_ms: nil))).to be_valid
    end

    it "is valid with an integer in the allowed range" do
      expect(described_class.new(valid_attrs.merge(slow_threshold_ms: 500))).to be_valid
    end

    it "rejects a value below the range minimum (< 100)" do
      expect(described_class.new(valid_attrs.merge(slow_threshold_ms: 50))).not_to be_valid
    end

    it "rejects a value above the range maximum (> 60000)" do
      expect(described_class.new(valid_attrs.merge(slow_threshold_ms: 70_000))).not_to be_valid
    end

    it "is nulled by clear_irrelevant_config when check_type flips to :tcp" do
      site = described_class.create!(valid_attrs.merge(slow_threshold_ms: 500))
      site.update!(check_type: :tcp, tcp_port: 22)
      expect(site.reload.slow_threshold_ms).to be_nil
    end

    it "is nulled by clear_irrelevant_config when check_type flips to :ssl" do
      site = described_class.create!(valid_attrs.merge(slow_threshold_ms: 500))
      site.update!(check_type: :ssl, tls_port: 443)
      expect(site.reload.slow_threshold_ms).to be_nil
    end

    it "is preserved for :content_match sites" do
      site = described_class.create!(
        valid_attrs.merge(
          check_type: :content_match,
          content_match_pattern: "ok",
          slow_threshold_ms: 500
        )
      )
      expect(site.reload.slow_threshold_ms).to eq(500)
    end
  end

  # PR #26 review finding: clear_irrelevant_config must also scrub
  # HTTP-only config (expected_status_codes, follow_redirects) when
  # flipping to a non-HTTP / non-content-match type, otherwise the
  # "normalizes stale config on every save" claim in the PR notes is
  # false for those two fields.
  describe "clear_irrelevant_config scrubs HTTP options on non-HTTP flips" do
    %i[ssl tcp dns].each do |target_type|
      context "when flipping from :http to :#{target_type}" do
        let(:site) do
          described_class.create!(
            valid_attrs.merge(
              check_type: :http,
              expected_status_codes: [ 200, 301 ],
              follow_redirects: false
            )
          )
        end

        let(:flip_attrs) do
          case target_type
          when :ssl then { check_type: :ssl, tls_port: 443 }
          when :tcp then { check_type: :tcp, tcp_port: 22 }
          when :dns then { check_type: :dns, dns_hostname: "example.com" }
          end
        end

        before { site.update!(flip_attrs) }

        it "nulls expected_status_codes" do
          expect(site.reload.expected_status_codes).to be_nil
        end

        it "resets follow_redirects to the DB default (true)" do
          expect(site.reload.follow_redirects).to be true
        end
      end
    end

    it "preserves HTTP options for :content_match sites" do
      site = described_class.create!(
        valid_attrs.merge(
          check_type: :http,
          expected_status_codes: [ 200, 301 ],
          follow_redirects: false
        )
      )
      site.update!(check_type: :content_match, content_match_pattern: "ok")
      expect(site.reload.expected_status_codes).to eq([ 200, 301 ])
      expect(site.reload.follow_redirects).to be false
    end
  end

  describe "expected_status_codes parsing + validation" do
    it "stores nil for a blank string" do
      site = described_class.new(valid_attrs.merge(expected_status_codes: ""))
      expect(site.expected_status_codes).to be_nil
    end

    it "parses a comma-separated integer string into an array" do
      site = described_class.new(valid_attrs.merge(expected_status_codes: "200, 301, 404"))
      expect(site.expected_status_codes).to eq([ 200, 301, 404 ])
    end

    it "tolerates extra whitespace" do
      site = described_class.new(valid_attrs.merge(expected_status_codes: "  200 ,201  ,  202 "))
      expect(site.expected_status_codes).to eq([ 200, 201, 202 ])
    end

    it "rejects non-integer tokens with a validation error" do
      site = described_class.new(valid_attrs.merge(expected_status_codes: "200, foo, 301"))
      expect(site).not_to be_valid
      expect(site.errors[:expected_status_codes].join).to match(/integers/)
    end

    it "rejects range-style strings (ranges are not supported)" do
      site = described_class.new(valid_attrs.merge(expected_status_codes: "200-299"))
      expect(site).not_to be_valid
    end

    it "rejects integers outside 100..599" do
      expect(described_class.new(valid_attrs.merge(expected_status_codes: "99, 200"))).not_to be_valid
      expect(described_class.new(valid_attrs.merge(expected_status_codes: "600"))).not_to be_valid
    end

    it "accepts a nil value as 'use default behavior'" do
      expect(described_class.new(valid_attrs.merge(expected_status_codes: nil))).to be_valid
    end

    it "round-trips an array set directly (already parsed)" do
      site = described_class.create!(valid_attrs.merge(expected_status_codes: [ 200, 301 ]))
      expect(site.reload.expected_status_codes).to eq([ 200, 301 ])
    end

    it "renders as a comma-separated string for the form display helper" do
      site = described_class.new(valid_attrs.merge(expected_status_codes: [ 200, 301 ]))
      expect(site.expected_status_codes_for_display).to eq("200, 301")
    end

    # PR #26 review finding: invalid input must survive form redisplay so
    # the user sees their own bad input alongside the validation error,
    # rather than a blank field that wiped what they typed.
    it "preserves the raw invalid string for form redisplay after a parse failure" do
      site = described_class.new(valid_attrs.merge(expected_status_codes: "200, foo, 301"))
      site.valid? # trigger the parse-error validator
      expect(site.expected_status_codes).to be_nil
      expect(site.expected_status_codes_for_display).to eq("200, foo, 301")
      expect(site.errors[:expected_status_codes]).to be_present
    end
  end

  describe "follow_redirects default" do
    it "defaults to true for new :http sites" do
      expect(described_class.new(valid_attrs).follow_redirects).to be true
    end
  end

  describe "content_match_pattern validation" do
    let(:cm_attrs) do
      valid_attrs.merge(check_type: :content_match, content_match_pattern: "Hello")
    end

    it "is valid for a :content_match site with a pattern" do
      expect(described_class.new(cm_attrs)).to be_valid
    end

    it "requires content_match_pattern when check_type is :content_match" do
      site = described_class.new(cm_attrs.merge(content_match_pattern: nil))
      expect(site).not_to be_valid
      expect(site.errors[:content_match_pattern]).to be_present
    end

    it "rejects a content_match_pattern longer than the configured max" do
      site = described_class.new(cm_attrs.merge(content_match_pattern: "x" * (Site::CONTENT_MATCH_PATTERN_MAX + 1)))
      expect(site).not_to be_valid
    end

    it "does not require content_match_pattern for an :http site" do
      expect(described_class.new(valid_attrs.merge(check_type: :http))).to be_valid
    end
  end

  describe "dns_hostname validation and url relaxation" do
    let(:dns_attrs) { { name: "DNS", check_type: :dns, dns_hostname: "example.com", interval_seconds: 60 } }

    it "is valid for a :dns site with a hostname and no url" do
      expect(described_class.new(dns_attrs)).to be_valid
    end

    it "does NOT require url when check_type is :dns" do
      site = described_class.new(dns_attrs.merge(url: nil))
      expect(site).to be_valid
    end

    it "requires dns_hostname when check_type is :dns" do
      site = described_class.new(dns_attrs.merge(dns_hostname: nil))
      expect(site).not_to be_valid
      expect(site.errors[:dns_hostname]).to be_present
    end

    it "rejects a dns_hostname with invalid characters" do
      site = described_class.new(dns_attrs.merge(dns_hostname: "bad host!"))
      expect(site).not_to be_valid
    end

    it "rejects a dns_hostname starting with a hyphen" do
      site = described_class.new(dns_attrs.merge(dns_hostname: "-bad.example"))
      expect(site).not_to be_valid
    end

    it "accepts a multi-label fully-qualified domain" do
      expect(described_class.new(dns_attrs.merge(dns_hostname: "sub.domain.example.com"))).to be_valid
    end

    it "does not require dns_hostname for an :http site" do
      expect(described_class.new(valid_attrs.merge(check_type: :http))).to be_valid
    end
  end

  describe "tcp_port validation" do
    let(:tcp_attrs) { valid_attrs.merge(check_type: :tcp, tcp_port: 22) }

    it "is valid for a :tcp site with a legal port" do
      expect(described_class.new(tcp_attrs)).to be_valid
    end

    it "requires tcp_port when check_type is :tcp" do
      site = described_class.new(tcp_attrs.merge(tcp_port: nil))
      expect(site).not_to be_valid
      expect(site.errors[:tcp_port]).to be_present
    end

    it "rejects a tcp_port of 0" do
      site = described_class.new(tcp_attrs.merge(tcp_port: 0))
      expect(site).not_to be_valid
    end

    it "does not require tcp_port for an :http site" do
      expect(described_class.new(valid_attrs.merge(check_type: :http))).to be_valid
    end
  end

  describe "tls_port validation" do
    let(:ssl_attrs) { valid_attrs.merge(check_type: :ssl, tls_port: 443) }

    it "is valid for an :ssl site with a legal port" do
      expect(described_class.new(ssl_attrs)).to be_valid
    end

    it "requires tls_port when check_type is :ssl" do
      site = described_class.new(ssl_attrs.merge(tls_port: nil))
      expect(site).not_to be_valid
      expect(site.errors[:tls_port]).to be_present
    end

    it "rejects a tls_port above 65535" do
      site = described_class.new(ssl_attrs.merge(tls_port: 70_000))
      expect(site).not_to be_valid
    end

    it "does not require tls_port for an :http site" do
      expect(described_class.new(valid_attrs.merge(check_type: :http))).to be_valid
    end
  end

  describe "clear_irrelevant_config callback" do
    it "runs the callback on validation" do
      site = described_class.new(valid_attrs)
      expect(site).to receive(:clear_irrelevant_config).and_call_original
      site.valid?
    end

    it "nulls tls_port when flipping from :ssl to :http" do
      site = described_class.create!(
        valid_attrs.merge(check_type: :ssl, tls_port: 8443)
      )
      site.update!(check_type: :http)
      expect(site.reload.tls_port).to be_nil
    end

    it "leaves tls_port alone for :ssl sites" do
      site = described_class.create!(
        valid_attrs.merge(check_type: :ssl, tls_port: 8443)
      )
      expect(site.reload.tls_port).to eq(8443)
    end

    it "nulls tcp_port when flipping from :tcp to :http" do
      site = described_class.create!(
        valid_attrs.merge(check_type: :tcp, tcp_port: 22)
      )
      site.update!(check_type: :http)
      expect(site.reload.tcp_port).to be_nil
    end

    it "leaves tcp_port alone for :tcp sites" do
      site = described_class.create!(
        valid_attrs.merge(check_type: :tcp, tcp_port: 22)
      )
      expect(site.reload.tcp_port).to eq(22)
    end

    it "nulls url when flipping to :dns" do
      site = described_class.create!(valid_attrs)
      site.update!(check_type: :dns, dns_hostname: "example.com")
      expect(site.reload.url).to be_nil
    end

    it "nulls dns_hostname when flipping from :dns to :http" do
      site = described_class.create!(
        name: "DNS", check_type: :dns, dns_hostname: "example.com", interval_seconds: 60
      )
      site.update!(check_type: :http, url: "https://example.com")
      expect(site.reload.dns_hostname).to be_nil
    end

    it "nulls content_match_pattern when flipping from :content_match to :http" do
      site = described_class.create!(
        valid_attrs.merge(check_type: :content_match, content_match_pattern: "Welcome")
      )
      site.update!(check_type: :http)
      expect(site.reload.content_match_pattern).to be_nil
    end
  end

  describe "#due?" do
    it "is true when the site has never been checked" do
      site = described_class.new(valid_attrs.merge(last_checked_at: nil))
      expect(site).to be_due
    end

    it "is true when last_checked_at is older than interval_seconds" do
      site = described_class.new(valid_attrs.merge(last_checked_at: 90.seconds.ago))
      expect(site).to be_due
    end

    it "is false when last_checked_at is within interval_seconds" do
      site = described_class.new(valid_attrs.merge(last_checked_at: 30.seconds.ago))
      expect(site).not_to be_due
    end

    it "is true at the exact boundary" do
      site = described_class.new(valid_attrs.merge(last_checked_at: 60.seconds.ago))
      expect(site).to be_due
    end
  end

  describe "alert noise controls" do
    describe "cooldown validation" do
      it "defaults cooldown_minutes to 5" do
        expect(described_class.new(valid_attrs).cooldown_minutes).to eq(5)
      end

      it "rejects a negative cooldown" do
        site = described_class.new(valid_attrs.merge(cooldown_minutes: -1))
        expect(site).not_to be_valid
        expect(site.errors[:cooldown_minutes]).to be_present
      end

      it "accepts a zero cooldown" do
        expect(described_class.new(valid_attrs.merge(cooldown_minutes: 0))).to be_valid
      end
    end

    describe "#alert_cooldown_expired?" do
      let(:site) { described_class.create!(valid_attrs.merge(cooldown_minutes: 5)) }

      it "returns true when no event has been recorded" do
        expect(site.alert_cooldown_expired?(:down)).to be(true)
      end

      it "returns true when the cooldown for the event has expired" do
        site.update!(last_alerted_events: { "down" => 10.minutes.ago.iso8601 })
        expect(site.alert_cooldown_expired?(:down)).to be(true)
      end

      it "returns false when the cooldown for the event is still active" do
        site.update!(last_alerted_events: { "down" => 1.minute.ago.iso8601 })
        expect(site.alert_cooldown_expired?(:down)).to be(false)
      end

      it "tracks events independently so down cooldown does not suppress up" do
        site.update!(last_alerted_events: { "down" => 1.minute.ago.iso8601 })
        expect(site.alert_cooldown_expired?(:up)).to be(true)
      end
    end

    describe "#record_alert_sent!" do
      let(:site) { described_class.create!(valid_attrs) }

      it "persists the event timestamp as ISO8601" do
        freeze_time = Time.zone.parse("2026-04-15T10:00:00Z")
        site.record_alert_sent!(:down, freeze_time)
        expect(site.reload.last_alerted_events).to include("down" => freeze_time.iso8601)
      end

      it "merges with existing event timestamps instead of replacing them" do
        site.record_alert_sent!(:down, 5.minutes.ago)
        site.record_alert_sent!(:up, Time.current)
        expect(site.reload.last_alerted_events.keys).to contain_exactly("down", "up")
      end
    end

    describe "quiet hours validation" do
      it "is valid when both start and end are nil" do
        expect(described_class.new(valid_attrs)).to be_valid
      end

      it "requires both start and end if either is present" do
        site = described_class.new(valid_attrs.merge(quiet_hours_start: "22:00"))
        expect(site).not_to be_valid
        expect(site.errors[:quiet_hours_end]).to be_present
      end

      it "accepts a valid timezone name" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "22:00",
          quiet_hours_end: "06:00",
          quiet_hours_timezone: "America/New_York"
        ))
        expect(site).to be_valid
      end

      it "rejects an unknown timezone name" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "22:00",
          quiet_hours_end: "06:00",
          quiet_hours_timezone: "Middle-earth/Shire"
        ))
        expect(site).not_to be_valid
        expect(site.errors[:quiet_hours_timezone]).to be_present
      end
    end

    describe "quiet_hours_timezone canonicalization (review finding #1)" do
      it "leaves an IANA identifier unchanged on assignment" do
        site = described_class.new(valid_attrs.merge(quiet_hours_timezone: "America/New_York"))
        expect(site.quiet_hours_timezone).to eq("America/New_York")
      end

      it "converts a Rails friendly name to its IANA identifier on assignment" do
        site = described_class.new(valid_attrs.merge(quiet_hours_timezone: "Eastern Time (US & Canada)"))
        expect(site.quiet_hours_timezone).to eq("America/New_York")
      end

      it "converts 'UTC' to 'Etc/UTC' on assignment" do
        site = described_class.new(valid_attrs.merge(quiet_hours_timezone: "UTC"))
        expect(site.quiet_hours_timezone).to eq("Etc/UTC")
      end

      it "strips surrounding whitespace before lookup" do
        site = described_class.new(valid_attrs.merge(quiet_hours_timezone: "  America/New_York  "))
        expect(site.quiet_hours_timezone).to eq("America/New_York")
      end

      it "passes invalid timezone names through unchanged so the validator rejects them" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "22:00",
          quiet_hours_end: "06:00",
          quiet_hours_timezone: "Middle-earth/Shire"
        ))
        expect(site.quiet_hours_timezone).to eq("Middle-earth/Shire")
        expect(site).not_to be_valid
      end

      it "treats blank values as nil" do
        site = described_class.new(valid_attrs.merge(quiet_hours_timezone: ""))
        expect(site.quiet_hours_timezone).to be_nil
      end

      it "persists the normalized IANA identifier across a save round-trip" do
        site = described_class.create!(valid_attrs.merge(
          quiet_hours_start: "09:00",
          quiet_hours_end: "17:00",
          quiet_hours_timezone: "Eastern Time (US & Canada)"
        ))
        expect(site.reload.quiet_hours_timezone).to eq("America/New_York")
      end
    end

    describe "#in_quiet_hours?" do
      it "returns false when no window is configured" do
        site = described_class.new(valid_attrs)
        expect(site.in_quiet_hours?).to be(false)
      end

      it "returns true inside a same-day window" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "09:00",
          quiet_hours_end: "17:00",
          quiet_hours_timezone: "UTC"
        ))
        expect(site.in_quiet_hours?(Time.utc(2026, 4, 15, 12, 0))).to be(true)
      end

      it "returns false outside a same-day window" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "09:00",
          quiet_hours_end: "17:00",
          quiet_hours_timezone: "UTC"
        ))
        expect(site.in_quiet_hours?(Time.utc(2026, 4, 15, 18, 0))).to be(false)
      end

      it "treats the start boundary as in-window (inclusive)" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "09:00",
          quiet_hours_end: "17:00",
          quiet_hours_timezone: "UTC"
        ))
        expect(site.in_quiet_hours?(Time.utc(2026, 4, 15, 9, 0))).to be(true)
      end

      it "treats the end boundary as out-of-window (exclusive)" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "09:00",
          quiet_hours_end: "17:00",
          quiet_hours_timezone: "UTC"
        ))
        expect(site.in_quiet_hours?(Time.utc(2026, 4, 15, 17, 0))).to be(false)
      end

      it "handles an overnight window that wraps past midnight" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "22:00",
          quiet_hours_end: "06:00",
          quiet_hours_timezone: "UTC"
        ))
        expect(site.in_quiet_hours?(Time.utc(2026, 4, 15, 23, 0))).to be(true)  # before midnight
        expect(site.in_quiet_hours?(Time.utc(2026, 4, 15, 3, 0))).to be(true)   # after midnight
        expect(site.in_quiet_hours?(Time.utc(2026, 4, 15, 12, 0))).to be(false) # midday
      end

      it "falls back to Rails.application.config.time_zone when quiet_hours_timezone is nil" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "09:00",
          quiet_hours_end: "17:00",
          quiet_hours_timezone: nil
        ))
        # Default Rails time_zone is UTC unless the app overrides it.
        default_zone = Rails.application.config.time_zone
        now_in_default = Time.zone.parse("2026-04-15 12:00:00").in_time_zone(default_zone)
        if now_in_default.hour.between?(9, 16)
          expect(site.in_quiet_hours?(now_in_default)).to be(true)
        end
      end

      it "respects DST transitions in America/New_York" do
        site = described_class.new(valid_attrs.merge(
          quiet_hours_start: "22:00",
          quiet_hours_end: "06:00",
          quiet_hours_timezone: "America/New_York"
        ))
        # 2026-03-08 02:00 local is the spring-forward gap (skipped).
        # 23:00 NY on 2026-03-07 is still in quiet hours.
        spring_night = ActiveSupport::TimeZone["America/New_York"].local(2026, 3, 7, 23, 0)
        expect(site.in_quiet_hours?(spring_night)).to be(true)

        # 2026-11-01 01:30 NY happens twice due to fall-back; quiet hours still true.
        fall_night = ActiveSupport::TimeZone["America/New_York"].local(2026, 11, 1, 1, 30)
        expect(site.in_quiet_hours?(fall_night)).to be(true)
      end
    end
  end

  describe "#propose_status (N=2 debounce)" do
    let(:site) { described_class.new(valid_attrs) }

    it "stashes the first candidate from unknown and returns unknown" do
      result = site.propose_status(:up)
      expect(result).to eq("unknown")
      expect(site.status).to eq("unknown")
      expect(site.candidate_status).to eq("up")
    end

    it "commits on the second consecutive same-status check" do
      site.propose_status(:up)
      result = site.propose_status(:up)
      expect(result).to eq("up")
      expect(site.status).to eq("up")
      expect(site.candidate_status).to be_nil
    end

    it "commits unknown → down → down (the critical-alert path)" do
      site.propose_status(:down)
      expect(site.status).to eq("unknown")
      result = site.propose_status(:down)
      expect(result).to eq("down")
      expect(site.status).to eq("down")
    end

    it "clears a pending candidate when the confirmed status is seen again" do
      site.status = "up"
      site.propose_status(:down)
      expect(site.candidate_status).to eq("down")
      site.propose_status(:up)
      expect(site.candidate_status).to be_nil
      expect(site.status).to eq("up")
    end

    it "ignores a single blip in the middle of a stable run" do
      site.status = "up"
      site.propose_status(:up)   # stable
      site.propose_status(:down) # blip candidate
      site.propose_status(:up)   # blip cleared
      expect(site.status).to eq("up")
      expect(site.candidate_status).to be_nil
    end

    it "commits down on the fifth check of a flap sequence" do
      site.status = "up"
      results = [ :down, :up, :down, :up, :down ].map { |s| site.propose_status(s) }
      # Trace: candidate=down, cleared, candidate=down, cleared, candidate=down → no commit yet
      expect(results).to eq(%w[up up up up up])
      expect(site.status).to eq("up")
      expect(site.candidate_status).to eq("down")
    end

    it "handles degraded transitions the same way as up/down" do
      site.status = "up"
      site.propose_status(:degraded)
      expect(site.candidate_status).to eq("degraded")
      site.propose_status(:degraded)
      expect(site.status).to eq("degraded")
    end

    it "records candidate_status_at when a new candidate is stashed" do
      now = Time.zone.parse("2026-04-15T10:00:00Z")
      site.propose_status(:up, now)
      expect(site.candidate_status_at).to eq(now)
    end

    it "does not persist any changes (caller owns persistence)" do
      site.save!
      original_updated_at = site.updated_at

      # Jump the clock so updated_at would visibly change if a save happened
      travel_to(10.minutes.from_now) do
        site.propose_status(:up)
      end

      expect(site).to be_changed
      site.reload
      expect(site.updated_at).to eq(original_updated_at)
      expect(site.candidate_status).to be_nil
    end
  end
end

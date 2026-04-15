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
end

require "rails_helper"

RSpec.describe SsrfGuard do
  def connection(passthrough_url: nil)
    Faraday.new do |f|
      f.use SsrfGuard
      f.adapter :test do |stubs|
        stubs.get(passthrough_url) { [ 200, {}, "ok" ] } if passthrough_url
      end
    end
  end

  it "delegates to IpGuard.check! with the request hostname" do
    expect(IpGuard).to receive(:check!).with("example.com").and_return(true)

    connection(passthrough_url: "https://example.com").get("https://example.com")
  end

  it "re-raises IpGuard::BlockedIpError as SsrfGuard::BlockedIpError" do
    allow(IpGuard).to receive(:check!).and_raise(IpGuard::BlockedIpError, "nope")

    expect { connection.get("http://blocked.example/") }.to raise_error(described_class::BlockedIpError, "nope")
  end

  it "exposes BlockedIpError as a Faraday::Error subclass so HttpChecker's rescue catches it" do
    expect(described_class::BlockedIpError.ancestors).to include(Faraday::Error)
  end

  it "passes the request through when IpGuard allows it" do
    allow(IpGuard).to receive(:check!).with("example.com").and_return(true)

    response = connection(passthrough_url: "https://example.com").get("https://example.com")
    expect(response.status).to eq(200)
  end
end

require "rails_helper"

RSpec.describe SsrfGuard do
  # Build a Faraday connection with SsrfGuard in the stack.
  # The test adapter is a stub-only backend — no real HTTP is made.
  # For blocked URLs, SsrfGuard raises before the adapter is invoked.
  # For allowed URLs, the adapter returns 200 when a matching stub is registered.
  def connection(passthrough_url: nil)
    Faraday.new do |f|
      f.use SsrfGuard
      f.adapter :test do |stubs|
        stubs.get(passthrough_url) { [ 200, {}, "ok" ] } if passthrough_url
      end
    end
  end

  def stub_dns(hostname, ips)
    allow(Resolv).to receive(:getaddresses).with(hostname).and_return(ips)
  end

  # ── Literal IP fast path (no DNS stub required) ──────────────────────────

  describe "literal IP addresses (blocked without DNS lookup)" do
    it "blocks IPv4 loopback 127.0.0.1" do
      expect { connection.get("http://127.0.0.1/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks the edge of loopback space 127.255.255.255" do
      expect { connection.get("http://127.255.255.255/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks RFC 1918 10.x" do
      expect { connection.get("http://10.0.0.1/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks RFC 1918 172.16.x" do
      expect { connection.get("http://172.16.0.1/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks RFC 1918 192.168.x" do
      expect { connection.get("http://192.168.1.1/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks link-local / cloud metadata 169.254.169.254" do
      expect { connection.get("http://169.254.169.254/latest/meta-data/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks carrier-grade NAT 100.64.x" do
      expect { connection.get("http://100.64.0.1/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks benchmark range 198.18.x" do
      expect { connection.get("http://198.18.0.1/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks IPv6 loopback [::1]" do
      expect { connection.get("http://[::1]/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks IPv6 ULA fc00:: space" do
      expect { connection.get("http://[fc00::1]/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks IPv6 ULA fd00:: space" do
      expect { connection.get("http://[fd00::1]/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks IPv6 link-local fe80::" do
      expect { connection.get("http://[fe80::1]/") }.to raise_error(described_class::BlockedIpError)
    end
  end

  # ── DNS resolution path ──────────────────────────────────────────────────

  describe "hostname-based URLs (DNS resolution)" do
    it "blocks when the hostname resolves to loopback" do
      stub_dns("localhost", [ "127.0.0.1" ])
      expect { connection.get("http://localhost/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks when the hostname resolves to a private RFC 1918 address" do
      stub_dns("internal.corp", [ "10.10.10.10" ])
      expect { connection.get("http://internal.corp/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks when any resolved address is private (multi-IP split-horizon guard)" do
      stub_dns("split.example", [ "93.184.216.34", "10.0.0.1" ])
      expect { connection.get("http://split.example/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks when the hostname does not resolve (NXDOMAIN — fail closed)" do
      stub_dns("does-not-exist.invalid", [])
      expect { connection.get("http://does-not-exist.invalid/") }.to raise_error(described_class::BlockedIpError)
    end

    it "blocks when a resolved address string is not parseable as an IP (fail closed)" do
      stub_dns("weird.example", [ "not-an-ip-address" ])
      expect { connection.get("http://weird.example/") }.to raise_error(described_class::BlockedIpError)
    end

    it "passes through when the hostname resolves to a public IP" do
      stub_dns("example.com", [ "93.184.216.34" ])
      response = connection(passthrough_url: "https://example.com").get("https://example.com")
      expect(response.status).to eq(200)
    end
  end
end

require "rails_helper"

RSpec.describe IpGuard do
  def forbid_dns
    allow(Resolv).to receive(:getaddresses) do |arg|
      raise "Resolv.getaddresses should not have been called for #{arg.inspect}"
    end
  end

  def stub_dns(hostname, addresses)
    allow(Resolv).to receive(:getaddresses).with(hostname).and_return(addresses)
  end

  describe ".check!" do
    context "with a literal blocked IPv4 (127.0.0.1)" do
      it "raises BlockedIpError without calling Resolv" do
        forbid_dns
        expect { described_class.check!("127.0.0.1") }.to raise_error(described_class::BlockedIpError)
      end
    end

    context "with a literal public IPv4 (1.1.1.1)" do
      it "passes without calling Resolv" do
        forbid_dns
        expect(described_class.check!("1.1.1.1")).to be true
      end
    end

    context "with a hostname resolving to a single public address" do
      it "passes" do
        stub_dns("example.com", [ "93.184.216.34" ])
        expect(described_class.check!("example.com")).to be true
      end
    end

    context "with a hostname resolving to multiple public addresses" do
      it "passes" do
        stub_dns("mirrored.example", [ "93.184.216.34", "8.8.8.8" ])
        expect(described_class.check!("mirrored.example")).to be true
      end
    end

    context "with a hostname where one of many resolved addresses is private (split-horizon)" do
      it "raises BlockedIpError because ANY private address blocks the host" do
        stub_dns("split.example", [ "93.184.216.34", "10.0.0.1" ])
        expect { described_class.check!("split.example") }.to raise_error(described_class::BlockedIpError)
      end
    end

    context "with NXDOMAIN (empty Resolv result)" do
      it "raises BlockedIpError — fail closed" do
        stub_dns("nope.example", [])
        expect { described_class.check!("nope.example") }.to raise_error(described_class::BlockedIpError)
      end
    end

    context "with an unparseable resolved address" do
      it "raises BlockedIpError — fail closed" do
        stub_dns("weird.example", [ "definitely-not-an-ip" ])
        expect { described_class.check!("weird.example") }.to raise_error(described_class::BlockedIpError)
      end
    end

    context "with a literal IPv6 ULA (fd12:3456::1 in fc00::/7)" do
      it "raises BlockedIpError without calling Resolv" do
        forbid_dns
        expect { described_class.check!("fd12:3456::1") }.to raise_error(described_class::BlockedIpError)
      end
    end

    context "with a literal IPv6 link-local (fe80::1)" do
      it "raises BlockedIpError without calling Resolv" do
        forbid_dns
        expect { described_class.check!("fe80::1") }.to raise_error(described_class::BlockedIpError)
      end
    end
  end
end

require "rails_helper"

RSpec.describe DnsChecker do
  let(:hostname) { "example.com" }

  def stub_resolve(addresses)
    allow(Resolv).to receive(:getaddresses).with(hostname).and_return(addresses)
  end

  describe ".check" do
    context "when resolution returns one public address" do
      before { stub_resolve([ "93.184.216.34" ]) }

      it "returns a CheckOutcome with no error_message" do
        expect(described_class.check(hostname: hostname).error_message).to be_nil
      end

      it "exposes the resolved addresses via metadata" do
        expect(described_class.check(hostname: hostname).metadata[:resolved_addresses])
          .to contain_exactly("93.184.216.34")
      end
    end

    context "when resolution returns multiple addresses (A + AAAA)" do
      before { stub_resolve([ "93.184.216.34", "2606:2800:220:1::248:1893" ]) }

      it "succeeds and reports all addresses in metadata" do
        result = described_class.check(hostname: hostname)
        expect(result.error_message).to be_nil
        expect(result.metadata[:resolved_addresses].size).to eq(2)
      end
    end

    context "when resolution returns a private address (NOT blocked — DNS-specific behavior)" do
      before { stub_resolve([ "10.0.0.1" ]) }

      it "still succeeds because DnsChecker deliberately does NOT call IpGuard" do
        expect(described_class.check(hostname: hostname).error_message).to be_nil
      end

      it "reports the private address in metadata so operators can see it" do
        expect(described_class.check(hostname: hostname).metadata[:resolved_addresses])
          .to contain_exactly("10.0.0.1")
      end
    end

    context "when resolution returns zero addresses (NXDOMAIN)" do
      before { stub_resolve([]) }

      it "returns an error CheckOutcome" do
        expect(described_class.check(hostname: hostname).error_message).to include("no addresses resolved")
      end

      it "exposes an empty resolved_addresses array in metadata" do
        expect(described_class.check(hostname: hostname).metadata[:resolved_addresses]).to eq([])
      end
    end

    context "when Resolv raises ResolvError" do
      before do
        allow(Resolv).to receive(:getaddresses)
          .with(hostname)
          .and_raise(Resolv::ResolvError, "no answer")
      end

      it "returns an error CheckOutcome" do
        expect(described_class.check(hostname: hostname).error_message).to include("Resolv::ResolvError")
      end
    end

    context "when IpGuard is explicitly NOT called" do
      before { stub_resolve([ "93.184.216.34" ]) }

      it "never invokes IpGuard.check! — DNS is the check, not the target" do
        expect(IpGuard).not_to receive(:check!)
        described_class.check(hostname: hostname)
      end
    end
  end
end

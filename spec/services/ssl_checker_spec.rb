require "rails_helper"
require "openssl"

RSpec.describe SslChecker do
  let(:host) { "example.com" }
  let(:port) { 443 }

  let(:tcp_socket) { instance_double(TCPSocket) }
  let(:ssl_socket) { instance_double(OpenSSL::SSL::SSLSocket) }

  def fake_cert(not_after:, subject: "/CN=example.com")
    cert = OpenSSL::X509::Certificate.new
    cert.not_after = not_after
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert
  end

  def stub_handshake(cert)
    allow(IpGuard).to receive(:check!).with(host).and_return(true)
    allow(Socket).to receive(:tcp).with(host, port, connect_timeout: anything).and_return(tcp_socket)
    allow(OpenSSL::SSL::SSLSocket).to receive(:new).with(tcp_socket).and_return(ssl_socket)
    allow(ssl_socket).to receive(:hostname=)
    allow(ssl_socket).to receive(:connect)
    allow(ssl_socket).to receive(:close)
    allow(tcp_socket).to receive(:close)
    allow(ssl_socket).to receive(:peer_cert).and_return(cert)
  end

  describe ".check" do
    context "with a cert expiring well beyond the critical floor" do
      # 90 days + a small buffer so the Float->Integer floor in
      # days_until_expiry can't drift below 90 during test execution.
      let(:cert) { fake_cert(not_after: Time.current + 90 * 86_400 + 3600) }
      before { stub_handshake(cert) }

      it "returns a CheckOutcome with no error_message (:up via job classification)" do
        expect(described_class.check(host: host, port: port).error_message).to be_nil
      end

      it "populates cert metadata" do
        metadata = described_class.check(host: host, port: port).metadata
        expect(metadata[:cert_not_after]).to be_within(1.second).of(cert.not_after)
        expect(metadata[:days_until_expiry]).to eq(90)
        expect(metadata[:cert_subject]).to include("example.com")
      end
    end

    context "with a cert under the critical floor" do
      let(:cert) { fake_cert(not_after: Time.current + 6 * 86_400 + 3600) }
      before { stub_handshake(cert) }

      it "returns a CheckOutcome with an error_message (:down)" do
        expect(described_class.check(host: host, port: port).error_message).to match(/expires in \d+ days/)
      end

      it "still populates cert metadata so the reason is visible" do
        expect(described_class.check(host: host, port: port).metadata[:days_until_expiry]).to eq(6)
      end
    end

    context "with an expired cert" do
      let(:cert) { fake_cert(not_after: Time.current - 2 * 86_400) }
      before { stub_handshake(cert) }

      it "returns a CheckOutcome with an error_message" do
        result = described_class.check(host: host, port: port)
        expect(result.error_message).to be_present
        expect(result.metadata[:days_until_expiry]).to eq(-2)
      end
    end

    context "when the IpGuard blocks the host" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_raise(IpGuard::BlockedIpError, "SSRF blocked")
      end

      it "returns an error CheckOutcome without opening a socket" do
        expect(Socket).not_to receive(:tcp)
        result = described_class.check(host: host, port: port)
        expect(result.error_message).to include("BlockedIpError")
      end
    end

    context "on connection refused" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_return(true)
        allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
      end

      it "returns an error CheckOutcome" do
        expect(described_class.check(host: host, port: port).error_message).to include("ECONNREFUSED")
      end
    end

    context "on TLS handshake error" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_return(true)
        allow(Socket).to receive(:tcp).with(host, port, connect_timeout: anything).and_return(tcp_socket)
        allow(OpenSSL::SSL::SSLSocket).to receive(:new).with(tcp_socket).and_return(ssl_socket)
        allow(ssl_socket).to receive(:hostname=)
        allow(ssl_socket).to receive(:connect).and_raise(OpenSSL::SSL::SSLError, "handshake failure")
        allow(ssl_socket).to receive(:close)
        allow(tcp_socket).to receive(:close)
      end

      it "returns an error CheckOutcome" do
        expect(described_class.check(host: host, port: port).error_message).to include("SSLError")
      end
    end

    context "on handshake timeout" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_return(true)
        allow(Socket).to receive(:tcp).with(host, port, connect_timeout: anything).and_return(tcp_socket)
        allow(OpenSSL::SSL::SSLSocket).to receive(:new).with(tcp_socket).and_return(ssl_socket)
        allow(ssl_socket).to receive(:hostname=)
        allow(ssl_socket).to receive(:connect).and_raise(Timeout::Error)
        allow(ssl_socket).to receive(:close)
        allow(tcp_socket).to receive(:close)
      end

      it "returns an error CheckOutcome" do
        expect(described_class.check(host: host, port: port).error_message).to include("Timeout::Error")
      end
    end
  end
end

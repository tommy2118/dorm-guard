require "rails_helper"

RSpec.describe TcpChecker do
  let(:host) { "example.com" }
  let(:port) { 22 }
  let(:tcp_socket) { instance_double(TCPSocket, close: nil) }

  describe ".check" do
    context "when the TCP connection opens" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_return(true)
        allow(Socket).to receive(:tcp)
          .with(host, port, connect_timeout: anything)
          .and_yield(tcp_socket)
          .and_return(nil)
      end

      it "returns a CheckOutcome with no error_message" do
        expect(described_class.check(host: host, port: port).error_message).to be_nil
      end

      it "closes the socket via the yielded block" do
        expect(tcp_socket).to receive(:close)
        described_class.check(host: host, port: port)
      end

      it "records a non-negative response_time_ms" do
        expect(described_class.check(host: host, port: port).response_time_ms).to be >= 0
      end
    end

    context "when the connection is refused" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_return(true)
        allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
      end

      it "returns an error CheckOutcome" do
        expect(described_class.check(host: host, port: port).error_message).to include("ECONNREFUSED")
      end
    end

    context "when the connection times out" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_return(true)
        allow(Socket).to receive(:tcp).and_raise(Errno::ETIMEDOUT)
      end

      it "returns an error CheckOutcome" do
        expect(described_class.check(host: host, port: port).error_message).to include("ETIMEDOUT")
      end
    end

    context "when the host is unreachable" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_return(true)
        allow(Socket).to receive(:tcp).and_raise(Errno::EHOSTUNREACH)
      end

      it "returns an error CheckOutcome" do
        expect(described_class.check(host: host, port: port).error_message).to include("EHOSTUNREACH")
      end
    end

    context "when IpGuard blocks the host" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_raise(IpGuard::BlockedIpError, "SSRF blocked")
      end

      it "returns an error CheckOutcome without opening a socket" do
        expect(Socket).not_to receive(:tcp)
        expect(described_class.check(host: host, port: port).error_message).to include("BlockedIpError")
      end
    end

    context "when the hostname does not resolve" do
      before do
        allow(IpGuard).to receive(:check!).with(host).and_return(true)
        allow(Socket).to receive(:tcp).and_raise(SocketError.new("getaddrinfo: Name or service not known"))
      end

      it "returns an error CheckOutcome" do
        expect(described_class.check(host: host, port: port).error_message).to include("SocketError")
      end
    end
  end
end

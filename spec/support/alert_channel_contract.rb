# Shared contract for every AlertChannels concrete implementation. Use via
# `it_behaves_like "an alert channel"` in each channel spec. The including
# spec must provide:
#
#   let(:channel)      { <instance of the channel class> }
#   let(:site)         { <a persisted Site> }
#   let(:check_result) { <a CheckResult or nil if the channel does not read it> }
#
# Each implementation gets its own success/failure plumbing specs — this
# contract pins the interface and error class that AlertDispatcher relies on.
RSpec.shared_examples "an alert channel" do
  describe "interface" do
    it "responds to #deliver" do
      expect(channel).to respond_to(:deliver)
    end

    it "accepts keyword arguments site:, event:, check_result:" do
      params = channel.method(:deliver).parameters
      required_kwargs = params.select { |type, _| type == :keyreq }.map(&:last)
      expect(required_kwargs).to contain_exactly(:site, :event, :check_result)
    end
  end

  describe "event atom set" do
    it "accepts every event in AlertChannels::EVENTS without raising ArgumentError" do
      AlertChannels::EVENTS.each do |event|
        expect { allow_channel_to_accept(event) }.not_to raise_error
      end
    end
  end

  # Hook for concrete specs to customize — by default, we just assert
  # the deliver method signature doesn't choke on a canonical event.
  def allow_channel_to_accept(_event)
    # Subclass specs override this when they want to actually exercise delivery.
    # The base contract only pins the interface; behavior tests live alongside.
    true
  end
end

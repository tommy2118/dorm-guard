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

    it "accepts keyword arguments site:, event:, check_result:, target:" do
      params = channel.method(:deliver).parameters
      required_kwargs = params.select { |type, _| type == :keyreq }.map(&:last)
      expect(required_kwargs).to contain_exactly(:site, :event, :check_result, :target)
    end
  end

  describe "error contract" do
    it "uses AlertChannels::DeliveryError as the documented failure type" do
      expect(AlertChannels::DeliveryError).to be < StandardError
    end
  end
end

require "rails_helper"

RSpec.describe CheckOutcome do
  let(:attrs) do
    {
      status_code: 200,
      response_time_ms: 42,
      error_message: nil,
      checked_at: Time.current,
      body: "hello",
      metadata: {}
    }
  end

  it "exposes every canonical field" do
    outcome = described_class.new(**attrs)

    expect(outcome.status_code).to eq(200)
    expect(outcome.response_time_ms).to eq(42)
    expect(outcome.error_message).to be_nil
    expect(outcome.body).to eq("hello")
    expect(outcome.metadata).to eq({})
  end

  it "is frozen so checkers cannot mutate an in-flight outcome" do
    expect(described_class.new(**attrs)).to be_frozen
  end

  it "requires all fields to be supplied" do
    expect { described_class.new(status_code: 200) }.to raise_error(ArgumentError)
  end
end

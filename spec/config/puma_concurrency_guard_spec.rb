require "rails_helper"

# The production deploy pins WEB_CONCURRENCY=1 in config/deploy.yml so that
# `plugin :solid_queue` inside Puma runs exactly one Solid Queue supervisor.
# The pin is enforced by a runtime guard in config/puma.rb that raises at
# boot if the combination SOLID_QUEUE_IN_PUMA=true + WEB_CONCURRENCY>1 is
# ever configured — a real check, not just documentation.
#
# This spec evaluates the guard logic in isolation. It cannot directly boot
# Puma, so it re-expresses the same conditional against stubbed ENV and
# asserts the right branch fires.
RSpec.describe "config/puma.rb — Solid Queue concurrency guard" do
  def guard_raises?(solid_queue_in_puma:, web_concurrency:)
    stubbed_env = {}
    stubbed_env["SOLID_QUEUE_IN_PUMA"] = solid_queue_in_puma if solid_queue_in_puma
    stubbed_env["WEB_CONCURRENCY"]     = web_concurrency     if web_concurrency

    stub_const("ENV", ENV.to_hash.merge(stubbed_env))

    return false unless ENV["SOLID_QUEUE_IN_PUMA"]
    ENV.fetch("WEB_CONCURRENCY", "1").to_i > 1
  end

  it "permits the default deploy (SOLID_QUEUE_IN_PUMA=true, WEB_CONCURRENCY=1)" do
    expect(guard_raises?(solid_queue_in_puma: "true", web_concurrency: "1")).to be false
  end

  it "permits running without Solid Queue in Puma at any concurrency" do
    expect(guard_raises?(solid_queue_in_puma: nil, web_concurrency: "4")).to be false
  end

  it "permits the scheduler to run at the implicit default concurrency (WEB_CONCURRENCY unset)" do
    expect(guard_raises?(solid_queue_in_puma: "true", web_concurrency: nil)).to be false
  end

  it "blocks the scheduler-double-fire combination (in-Puma + WEB_CONCURRENCY=2)" do
    expect(guard_raises?(solid_queue_in_puma: "true", web_concurrency: "2")).to be true
  end

  it "blocks any WEB_CONCURRENCY > 1 when Solid Queue is in Puma" do
    expect(guard_raises?(solid_queue_in_puma: "true", web_concurrency: "10")).to be true
  end

  describe "the puma.rb source" do
    let(:puma_rb) { Rails.root.join("config/puma.rb").read }

    it "includes the runtime guard (not just a comment)" do
      expect(puma_rb).to match(
        /ENV\["SOLID_QUEUE_IN_PUMA"\]\s*&&\s*ENV\.fetch\("WEB_CONCURRENCY",\s*"1"\)\.to_i\s*>\s*1/
      )
    end

    it "raises with an actionable error message pointing at the ADR" do
      expect(puma_rb).to include("docs/decisions/pr-0021-kamal-deploy.md")
      expect(puma_rb).to include("Refusing to boot")
      expect(puma_rb).to include("dedicated Kamal accessory")
    end
  end
end

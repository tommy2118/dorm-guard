require "rails_helper"

RSpec.describe ScheduleDueChecksJob, type: :job do
  describe "#perform" do
    let!(:never_checked) do
      Site.create!(name: "Never Checked", url: "https://never.example.com", interval_seconds: 60)
    end

    let!(:recently_checked) do
      Site.create!(
        name: "Recently Checked",
        url: "https://recent.example.com",
        interval_seconds: 60,
        last_checked_at: 30.seconds.ago
      )
    end

    let!(:overdue) do
      Site.create!(
        name: "Overdue",
        url: "https://overdue.example.com",
        interval_seconds: 60,
        last_checked_at: 90.seconds.ago
      )
    end

    it "enqueues PerformCheckJob for sites that have never been checked" do
      expect { described_class.perform_now }
        .to have_enqueued_job(PerformCheckJob).with(never_checked.id)
    end

    it "enqueues PerformCheckJob for overdue sites" do
      expect { described_class.perform_now }
        .to have_enqueued_job(PerformCheckJob).with(overdue.id)
    end

    it "does NOT enqueue PerformCheckJob for recently checked sites" do
      expect { described_class.perform_now }
        .not_to have_enqueued_job(PerformCheckJob).with(recently_checked.id)
    end
  end
end

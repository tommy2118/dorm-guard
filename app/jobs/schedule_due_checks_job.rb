class ScheduleDueChecksJob < ApplicationJob
  queue_as :default

  def perform
    Site.find_each do |site|
      PerformCheckJob.perform_later(site.id) if site.due?
    end
  end
end

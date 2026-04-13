require "rails_helper"

RSpec.describe "Database schema invariants", type: :model do
  describe "check_results indexes" do
    subject(:indexes) { ActiveRecord::Base.connection.indexes(:check_results) }

    it "has the (site_id, checked_at desc) composite index that SitesController#show depends on" do
      composite = indexes.find { |i| i.columns == [ "site_id", "checked_at" ] }

      expect(composite).to be_present,
        "Missing composite index on (site_id, checked_at). " \
        "SitesController#show paginates @site.check_results.order(checked_at: :desc) " \
        "and will go O(n log n) on large histories without this index."
    end

    it "orders the composite index's checked_at column descending" do
      composite = indexes.find { |i| i.columns == [ "site_id", "checked_at" ] }

      expect(composite.orders).to eq("checked_at" => :desc),
        "Composite index exists but is not desc-ordered on checked_at. " \
        "The detail page's order(checked_at: :desc) read will not use the index."
    end
  end
end

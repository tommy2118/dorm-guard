class AddSlowThresholdMsToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :slow_threshold_ms, :integer
  end
end

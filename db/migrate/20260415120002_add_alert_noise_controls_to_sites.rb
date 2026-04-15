class AddAlertNoiseControlsToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :last_alerted_events, :text
    add_column :sites, :cooldown_minutes, :integer, null: false, default: 5
    add_column :sites, :quiet_hours_start, :time
    add_column :sites, :quiet_hours_end, :time
    add_column :sites, :quiet_hours_timezone, :string
  end
end

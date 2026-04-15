class AddHttpOptionsToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :follow_redirects, :boolean, default: true, null: false
    add_column :sites, :expected_status_codes, :text
  end
end

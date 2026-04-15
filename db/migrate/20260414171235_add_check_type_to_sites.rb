class AddCheckTypeToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :check_type, :integer, null: false, default: 0
  end
end

class RelaxUrlNullConstraintOnSites < ActiveRecord::Migration[8.1]
  def change
    change_column_null :sites, :url, true
  end
end

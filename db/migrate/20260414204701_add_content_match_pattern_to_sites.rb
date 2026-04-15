class AddContentMatchPatternToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :content_match_pattern, :string
  end
end

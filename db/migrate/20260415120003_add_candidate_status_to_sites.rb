class AddCandidateStatusToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :candidate_status, :integer
    add_column :sites, :candidate_status_at, :datetime
  end
end

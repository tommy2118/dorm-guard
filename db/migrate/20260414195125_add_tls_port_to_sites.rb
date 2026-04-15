class AddTlsPortToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :tls_port, :integer
  end
end

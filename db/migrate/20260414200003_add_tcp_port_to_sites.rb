class AddTcpPortToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :tcp_port, :integer
  end
end

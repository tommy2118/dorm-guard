class AddDnsHostnameToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :dns_hostname, :string
  end
end

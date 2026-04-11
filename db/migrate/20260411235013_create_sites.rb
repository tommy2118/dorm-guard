class CreateSites < ActiveRecord::Migration[8.1]
  def change
    create_table :sites do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.integer :interval_seconds, null: false
      t.integer :status, null: false, default: 0
      t.datetime :last_checked_at

      t.timestamps
    end
  end
end

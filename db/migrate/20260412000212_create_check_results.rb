class CreateCheckResults < ActiveRecord::Migration[8.1]
  def change
    create_table :check_results do |t|
      t.references :site, null: false, foreign_key: true
      t.integer :status_code
      t.integer :response_time_ms, null: false
      t.text :error_message
      t.datetime :checked_at, null: false

      t.timestamps
    end

    add_index :check_results, [ :site_id, :checked_at ], order: { checked_at: :desc }
  end
end

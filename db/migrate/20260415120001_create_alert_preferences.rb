class CreateAlertPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_preferences do |t|
      t.references :site, null: false, foreign_key: true, index: true
      t.integer :channel, null: false
      t.string :target, null: false
      t.text :events, null: false
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end
  end
end

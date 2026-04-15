# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_15_120001) do
  create_table "alert_preferences", force: :cascade do |t|
    t.integer "channel", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.text "events", null: false
    t.integer "site_id", null: false
    t.string "target", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_alert_preferences_on_site_id"
  end

  create_table "check_results", force: :cascade do |t|
    t.datetime "checked_at", null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.integer "response_time_ms", null: false
    t.integer "site_id", null: false
    t.integer "status_code"
    t.datetime "updated_at", null: false
    t.index ["site_id", "checked_at"], name: "index_check_results_on_site_id_and_checked_at", order: { checked_at: :desc }
    t.index ["site_id"], name: "index_check_results_on_site_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "sites", force: :cascade do |t|
    t.integer "check_type", default: 0, null: false
    t.string "content_match_pattern"
    t.datetime "created_at", null: false
    t.string "dns_hostname"
    t.text "expected_status_codes"
    t.boolean "follow_redirects", default: true, null: false
    t.integer "interval_seconds", null: false
    t.datetime "last_checked_at"
    t.string "name", null: false
    t.integer "slow_threshold_ms"
    t.integer "status", default: 0, null: false
    t.integer "tcp_port"
    t.integer "tls_port"
    t.datetime "updated_at", null: false
    t.string "url"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "alert_preferences", "sites"
  add_foreign_key "check_results", "sites"
  add_foreign_key "sessions", "users"
end

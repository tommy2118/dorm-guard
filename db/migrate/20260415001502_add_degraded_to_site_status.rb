class AddDegradedToSiteStatus < ActiveRecord::Migration[8.1]
  # Documentation-only migration. Site.status is an integer-backed enum,
  # and Slice 9 appends :degraded at integer 4 (skipping integer 3) without
  # renumbering :down at 2. No schema change is needed — existing rows
  # stay at their integer values and the new enum key is available for
  # writes. This migration exists so the schema_migrations table has an
  # audit trail for when :degraded joined the enum.
  def change
  end
end

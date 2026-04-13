Site.find_or_create_by!(name: "Example (always up)") do |site|
  site.url = "https://example.com"
  site.interval_seconds = 60
end

Site.find_or_create_by!(name: "Example 404 (always down)") do |site|
  site.url = "https://example.com/definitely-not-a-real-page"
  site.interval_seconds = 60
end

# Extra seeds exist so the manual smoke test exercises index pagination
# (Pagy default limit: 25). Each site points at a distinct example.com
# subdomain so it looks realistic in the table.
30.times do |i|
  number = format("%02d", i + 1)
  Site.find_or_create_by!(name: "Fixture #{number}") do |site|
    site.url = "https://example.com/sample-#{number}"
    site.interval_seconds = 60
  end
end

puts "Seeded #{Site.count} sites."

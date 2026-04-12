Site.find_or_create_by!(name: "Example (always up)") do |site|
  site.url = "https://example.com"
  site.interval_seconds = 60
end

Site.find_or_create_by!(name: "Example 404 (always down)") do |site|
  site.url = "https://example.com/definitely-not-a-real-page"
  site.interval_seconds = 60
end

puts "Seeded #{Site.count} sites."

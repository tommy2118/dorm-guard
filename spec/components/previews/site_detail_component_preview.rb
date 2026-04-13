class SiteDetailComponentPreview < ViewComponent::Preview
  def up_site
    render(SiteDetailComponent.new(site: Site.new(
      name: "Production site",
      url: "https://example.com",
      interval_seconds: 60,
      status: :up,
      last_checked_at: 2.minutes.ago
    )))
  end

  def down_site
    render(SiteDetailComponent.new(site: Site.new(
      name: "Broken site",
      url: "https://broken.example.com",
      interval_seconds: 30,
      status: :down,
      last_checked_at: 10.seconds.ago
    )))
  end

  def unknown_site
    render(SiteDetailComponent.new(site: Site.new(
      name: "Just added",
      url: "https://new.example.com",
      interval_seconds: 120,
      status: :unknown,
      last_checked_at: nil
    )))
  end
end

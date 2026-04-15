class SiteFormComponentPreview < ViewComponent::Preview
  def new_site
    render(SiteFormComponent.new(site: Site.new))
  end

  def new_ssl_site
    render(SiteFormComponent.new(site: Site.new(check_type: :ssl, tls_port: 443)))
  end

  def new_tcp_site
    render(SiteFormComponent.new(site: Site.new(check_type: :tcp, tcp_port: 22)))
  end

  def new_dns_site
    render(SiteFormComponent.new(site: Site.new(check_type: :dns, dns_hostname: "example.com")))
  end

  def new_content_match_site
    render(SiteFormComponent.new(
      site: Site.new(check_type: :content_match, content_match_pattern: "Welcome")
    ))
  end

  def with_errors
    site = Site.new(name: "", url: "not-a-url", interval_seconds: 10)
    site.valid?
    render(SiteFormComponent.new(site: site))
  end

  # Slice 8a — noise control variants.
  def with_quiet_hours
    render(SiteFormComponent.new(
      site: Site.new(
        name: "Example",
        url: "https://example.com",
        interval_seconds: 60,
        cooldown_minutes: 10,
        quiet_hours_start: "22:00",
        quiet_hours_end: "06:00",
        quiet_hours_timezone: "America/New_York"
      )
    ))
  end

  def noise_controls_disabled
    render(SiteFormComponent.new(
      site: Site.new(
        name: "Always-on",
        url: "https://example.com",
        interval_seconds: 60,
        cooldown_minutes: 0
      )
    ))
  end
end

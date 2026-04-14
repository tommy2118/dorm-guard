class SiteFormComponentPreview < ViewComponent::Preview
  def new_site
    render(SiteFormComponent.new(site: Site.new))
  end

  def new_ssl_site
    render(SiteFormComponent.new(site: Site.new(check_type: :ssl, tls_port: 443)))
  end

  def with_errors
    site = Site.new(name: "", url: "not-a-url", interval_seconds: 10)
    site.valid?
    render(SiteFormComponent.new(site: site))
  end
end

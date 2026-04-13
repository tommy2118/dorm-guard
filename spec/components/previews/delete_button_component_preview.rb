class DeleteButtonComponentPreview < ViewComponent::Preview
  def default
    site = Site.new(id: 1, name: "Example site", url: "https://example.com", interval_seconds: 60)
    render(DeleteButtonComponent.new(site: site))
  end
end

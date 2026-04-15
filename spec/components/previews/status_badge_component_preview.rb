class StatusBadgeComponentPreview < ViewComponent::Preview
  def up
    render(StatusBadgeComponent.new(status: :up))
  end

  def down
    render(StatusBadgeComponent.new(status: :down))
  end

  def degraded
    render(StatusBadgeComponent.new(status: :degraded))
  end

  def unknown
    render(StatusBadgeComponent.new(status: :unknown))
  end
end

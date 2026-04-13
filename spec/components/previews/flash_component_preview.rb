class FlashComponentPreview < ViewComponent::Preview
  def notice
    render(FlashComponent.new(flash: { "notice" => "Site created successfully." }))
  end

  def alert
    render(FlashComponent.new(flash: { "alert" => "Site could not be saved." }))
  end

  def both
    render(FlashComponent.new(flash: { "notice" => "Saved.", "alert" => "But check this." }))
  end

  def empty
    render(FlashComponent.new(flash: {}))
  end
end

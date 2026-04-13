class FlashComponent < ApplicationComponent
  CLASSES_BY_KEY = {
    "notice" => "alert alert-success",
    "alert" => "alert alert-error"
  }.freeze

  def initialize(flash:)
    @flash = flash
  end

  def entries
    @flash.to_h.slice(*CLASSES_BY_KEY.keys)
  end

  def css_classes_for(key)
    CLASSES_BY_KEY.fetch(key.to_s)
  end
end

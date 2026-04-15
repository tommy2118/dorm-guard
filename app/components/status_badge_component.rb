class StatusBadgeComponent < ApplicationComponent
  CLASSES_BY_STATUS = {
    up: "badge badge-success",
    down: "badge badge-error",
    degraded: "badge badge-warning",
    unknown: "badge badge-ghost"
  }.freeze

  def initialize(status:)
    @status = status.to_sym
  end

  def css_classes
    CLASSES_BY_STATUS.fetch(@status, CLASSES_BY_STATUS.fetch(:unknown))
  end

  def label
    @status.to_s
  end
end

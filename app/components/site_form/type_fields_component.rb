module SiteForm
  class TypeFieldsComponent < ApplicationComponent
    def initialize(form:, site:)
      @form = form
      @site = site
    end

    attr_reader :form, :site
  end
end

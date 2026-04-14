module SiteForm
  class DnsFieldsComponent < ApplicationComponent
    def initialize(form:, site:)
      @form = form
      @site = site
    end

    attr_reader :form, :site

    def field_error(attribute)
      messages = site.errors[attribute]
      messages.first if messages.any?
    end
  end
end

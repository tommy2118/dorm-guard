require "rails_helper"

RSpec.describe SiteFormComponent, type: :component do
  let(:new_site) { Site.new }
  let(:persisted_site) do
    Site.create!(
      name: "Example",
      url: "https://example.com",
      interval_seconds: 60
    )
  end

  describe "#heading and #submit_label" do
    it "uses the new labels for an unpersisted record" do
      component = described_class.new(site: new_site)
      expect(component.heading).to eq("New site")
      expect(component.submit_label).to eq("Create site")
    end

    it "uses the edit labels for a persisted record" do
      component = described_class.new(site: persisted_site)
      expect(component.heading).to eq("Edit site")
      expect(component.submit_label).to eq("Update site")
    end
  end

  describe "rendering for a new site" do
    before do
      with_request_url "/sites/new" do
        render_inline(described_class.new(site: new_site))
      end
    end

    it "renders the 'New site' heading" do
      expect(page).to have_css("h1", text: "New site")
    end

    it "renders the 'Create site' submit button" do
      expect(page).to have_button("Create site")
    end

    it "renders DaisyUI bordered inputs for name, url, and interval_seconds" do
      expect(page).to have_css("input[name='site[name]'].input.input-bordered")
      expect(page).to have_css("input[name='site[url]'].input.input-bordered")
      expect(page).to have_css("input[name='site[interval_seconds]'].input.input-bordered")
    end

    it "renders a check_type select with HTTP / SSL / TCP options" do
      expect(page).to have_css("select[name='site[check_type]'].select.select-bordered")
      expect(page).to have_css("select[name='site[check_type]'] option[value='http']", text: "HTTP")
      expect(page).to have_css("select[name='site[check_type]'] option[value='ssl']", text: /SSL/)
      expect(page).to have_css("select[name='site[check_type]'] option[value='tcp']", text: /TCP/)
    end

    it "does not render tls_port or tcp_port inputs for a default :http site" do
      # The per-type fields dispatcher renders nothing for :http — the
      # shell owns only the shared fields.
      expect(page).not_to have_css("input[name='site[tls_port]']")
      expect(page).not_to have_css("input[name='site[tcp_port]']")
    end

    it "renders a Cancel link to the sites index" do
      expect(page).to have_link("Cancel", href: "/sites")
    end
  end

  describe "rendering for a new :ssl site" do
    before do
      with_request_url "/sites/new" do
        render_inline(described_class.new(site: Site.new(check_type: :ssl)))
      end
    end

    it "renders the TLS port input with DEFAULT_TLS_PORT as initial value" do
      expect(page).to have_css("input[name='site[tls_port]'][value='443']")
    end

    it "does not render the TCP port input" do
      expect(page).not_to have_css("input[name='site[tcp_port]']")
    end
  end

  describe "rendering for a new :tcp site" do
    before do
      with_request_url "/sites/new" do
        render_inline(described_class.new(site: Site.new(check_type: :tcp)))
      end
    end

    it "renders the TCP port input with DEFAULT_TCP_PORT as initial value" do
      expect(page).to have_css("input[name='site[tcp_port]'][value='80']")
    end

    it "does not render the TLS port input" do
      expect(page).not_to have_css("input[name='site[tls_port]']")
    end
  end

  describe "rendering for a new :dns site" do
    before do
      with_request_url "/sites/new" do
        render_inline(described_class.new(site: Site.new(check_type: :dns)))
      end
    end

    it "renders the dns_hostname input" do
      expect(page).to have_css("input[name='site[dns_hostname]']")
    end

    it "does NOT render the url field (DNS sites don't have a URL)" do
      expect(page).not_to have_css("input[name='site[url]']")
    end

    it "still renders the name and interval fields" do
      expect(page).to have_css("input[name='site[name]']")
      expect(page).to have_css("input[name='site[interval_seconds]']")
    end
  end

  describe "rendering for a new :content_match site" do
    before do
      with_request_url "/sites/new" do
        render_inline(described_class.new(site: Site.new(check_type: :content_match)))
      end
    end

    it "renders the content_match_pattern input" do
      expect(page).to have_css("input[name='site[content_match_pattern]']")
    end

    it "renders the 1 MiB truncation helper text" do
      expect(page).to have_text(/first 1 MiB/)
    end

    it "still renders the url field (content-match uses HTTP under the hood)" do
      expect(page).to have_css("input[name='site[url]']")
    end
  end

  describe "rendering with validation errors" do
    it "renders inline errors and input-error classes for invalid fields" do
      invalid_site = Site.new(name: "", url: "not-a-url", interval_seconds: 10)
      invalid_site.valid?

      with_request_url "/sites" do
        render_inline(described_class.new(site: invalid_site))
      end

      expect(page).to have_css("input[name='site[name]'].input-error")
      expect(page).to have_css("input[name='site[url]'].input-error")
      expect(page).to have_css("input[name='site[interval_seconds]'].input-error")
      expect(page).to have_css("p.text-error", minimum: 3)
    end
  end

  describe "alert noise-control fields" do
    before do
      with_request_url "/sites/new" do
        render_inline(described_class.new(site: new_site))
      end
    end

    it "renders the Alert noise controls divider" do
      expect(page).to have_css("div.divider", text: "Alert noise controls")
    end

    it "renders the cooldown_minutes number input" do
      expect(page).to have_css("input[name='site[cooldown_minutes]'].input.input-bordered")
    end

    it "renders the quiet_hours_start and quiet_hours_end time inputs" do
      expect(page).to have_css("input[name='site[quiet_hours_start]'][type='time']")
      expect(page).to have_css("input[name='site[quiet_hours_end]'][type='time']")
    end

    it "renders the quiet_hours_timezone select with IANA identifiers as option values" do
      expect(page).to have_css("select[name='site[quiet_hours_timezone]'].select.select-bordered")
      # Option VALUES are IANA identifiers so the <select> matches what
      # Site#normalizes persists. Labels remain human-readable Rails
      # formatted strings (e.g., "(GMT-05:00) Eastern Time (US & Canada)").
      expect(page).to have_css("select[name='site[quiet_hours_timezone]'] option[value='America/New_York']")
      expect(page).to have_css("select[name='site[quiet_hours_timezone]'] option[value='Etc/UTC']")
    end

    it "offers a blank option that falls back to the Rails default time zone" do
      expect(page).to have_css("select[name='site[quiet_hours_timezone]'] option[value='']", text: /default Rails/)
    end

    it "describes the critical override in help text" do
      expect(page).to have_text(/down.*still fire/)
    end
  end

  describe "quiet_hours_timezone pre-selection round-trip (review finding #1)" do
    it "pre-selects the persisted IANA timezone on an existing site's edit form" do
      persisted_site = Site.create!(
        name: "NYC API",
        url: "https://example.com",
        interval_seconds: 60,
        quiet_hours_start: "22:00",
        quiet_hours_end: "06:00",
        quiet_hours_timezone: "America/New_York"
      )

      with_request_url "/sites/#{persisted_site.id}/edit" do
        render_inline(described_class.new(site: persisted_site))
      end

      # The select must actually have an <option> whose value matches the
      # persisted tz. Without this, the form would render no option as
      # selected, and a save would silently wipe the timezone.
      expect(page).to have_css(
        "select[name='site[quiet_hours_timezone]'] option[value='America/New_York'][selected]"
      )
    end

    it "pre-selects even when the site was persisted from a Rails friendly name input (normalized to IANA)" do
      persisted_site = Site.create!(
        name: "Also NYC",
        url: "https://example.com",
        interval_seconds: 60,
        quiet_hours_start: "22:00",
        quiet_hours_end: "06:00",
        quiet_hours_timezone: "Eastern Time (US & Canada)"
      )

      with_request_url "/sites/#{persisted_site.id}/edit" do
        render_inline(described_class.new(site: persisted_site))
      end

      expect(page).to have_css(
        "select[name='site[quiet_hours_timezone]'] option[value='America/New_York'][selected]"
      )
    end
  end

  describe "noise-control validation rendering" do
    it "flags quiet_hours_end as invalid when only one of the pair is set" do
      invalid_site = Site.new(
        name: "Example",
        url: "https://example.com",
        interval_seconds: 60,
        quiet_hours_start: "22:00",
        quiet_hours_end: nil
      )
      invalid_site.valid?

      with_request_url "/sites/new" do
        render_inline(described_class.new(site: invalid_site))
      end

      expect(page).to have_css("input[name='site[quiet_hours_end]'].input-error")
    end
  end
end

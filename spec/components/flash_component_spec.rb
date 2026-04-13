require "rails_helper"

RSpec.describe FlashComponent, type: :component do
  it "renders nothing when the flash is empty" do
    render_inline(described_class.new(flash: {}))
    expect(page).to have_no_css("div[role='alert']")
  end

  it "renders a success alert for :notice" do
    render_inline(described_class.new(flash: { "notice" => "Saved." }))
    expect(page).to have_css("div.alert.alert-success", text: "Saved.")
  end

  it "renders an error alert for :alert" do
    render_inline(described_class.new(flash: { "alert" => "Something broke." }))
    expect(page).to have_css("div.alert.alert-error", text: "Something broke.")
  end

  it "renders both alerts when both keys are set" do
    render_inline(described_class.new(flash: { "notice" => "Yes", "alert" => "No" }))
    expect(page).to have_css("div.alert.alert-success", text: "Yes")
    expect(page).to have_css("div.alert.alert-error", text: "No")
  end

  it "ignores flash keys it does not know about" do
    render_inline(described_class.new(flash: { "info" => "ignored" }))
    expect(page).to have_no_css("div[role='alert']")
  end
end

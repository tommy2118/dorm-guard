# Lookbook previews only matter in development — the Lookbook engine
# is mounted only when Rails.env.development? in config/routes.rb, and
# the preview classes themselves live under spec/components/previews
# (a test-scope path, not loaded in production). Registering the path
# unconditionally causes production's eager_load to scan the previews
# directory and hit `uninitialized constant FlashComponentPreview`
# etc., because Lookbook's Preview base class isn't available outside
# development.
if Rails.env.development?
  Rails.application.config.view_component.previews.paths = [
    Rails.root.join("spec/components/previews").to_s
  ]
end

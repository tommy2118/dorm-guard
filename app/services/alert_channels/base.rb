module AlertChannels
  # Abstract interface. Exists only to pin the signature — concrete channels
  # implement #deliver and raise AlertChannels::DeliveryError on failure.
  class Base
    def deliver(site:, event:, check_result:)
      raise NotImplementedError
    end
  end
end

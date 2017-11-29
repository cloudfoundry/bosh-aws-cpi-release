module Bosh::AwsCloud
  class TagManager

    MAX_TAG_KEY_LENGTH = 127
    MAX_TAG_VALUE_LENGTH = 255

    # Add a tag to something, make sure that the tag conforms to the
    # AWS limitation of 127 character key and 255 character value
    def self.tag(taggable, key, value)
      return if key.nil? || value.nil?
      self.tags(taggable, { key => value})
    end

    def self.tags(taggable, tags)
      return if tags.nil? || tags.keys.length == 0

      errors = [Aws::EC2::Errors::InvalidAMIIDNotFound,
        Aws::EC2::Errors::InvalidInstanceIDNotFound,
        Aws::EC2::Errors::InvalidVolumeNotFound]

      begin
        Bosh::Common.retryable(tries: 30, on: errors) do
          logger.info("attempting to tag object: #{taggable.id}")
          taggable.create_tags({tags: format_tags(tags)})
          true
        end
      rescue Aws::EC2::Errors::InvalidParameterValue => e
        logger.error("could not tag #{taggable.id}: #{e.message}")
      end
    end

    def self.logger
      Bosh::Clouds::Config.logger
    end

    private

    def self.format_tags(tags)
      formatted_tags = tags.map do |k, v|
        if !k.nil? && !v.nil?
          trimmed_key = k.to_s.slice(0, MAX_TAG_KEY_LENGTH)
          trimmed_value = v.to_s.slice(0, MAX_TAG_VALUE_LENGTH)

          {
            key: trimmed_key,
            value: trimmed_value
          }
        end
      end

      formatted_tags.compact
    end
  end
end

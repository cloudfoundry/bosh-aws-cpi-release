module Bosh::AwsCloud
  class TagManager

    MAX_TAG_KEY_LENGTH = 127
    MAX_TAG_VALUE_LENGTH = 255

    # Add a tag to something, make sure that the tag conforms to the
    # AWS limitation of 127 character key and 255 character value
    def self.tag(taggable, key, value)
      return if key.nil? || value.nil?

      create_tags(taggable, key => value)
    end

    def self.create_tags(taggable, tags)
      return if tags.nil? || tags.keys.empty?

      errors = [Aws::EC2::Errors::InvalidAMIIDNotFound,
                Aws::EC2::Errors::InvalidInstanceIDNotFound,
                Aws::EC2::Errors::InvalidVolumeNotFound,
                Aws::EC2::Errors::InvalidSnapshotNotFound]

      begin
        Bosh::Common.retryable(tries: 30, on: errors) do
          logger.info("attempting to tag object: #{taggable.id}")
          taggable.create_tags(tags: format_tags(tags))
          true
        end
      rescue Aws::EC2::Errors::InvalidParameterValue => e
        logger.error("could not tag #{taggable.id}: #{e.message}")
      end
    end

    def self.logger
      Bosh::Clouds::Config.logger
    end

    def self.tags_hash(value, default: nil)
      value.is_a?(Hash) ? value.dup : default
    end

    def self.format_tags(tags)
      formatted_tags = tags.map do |k, v|
        next unless !k.nil? && !v.nil?

        trimmed_key = k.to_s.slice(0, MAX_TAG_KEY_LENGTH)
        trimmed_value = v.to_s.slice(0, MAX_TAG_VALUE_LENGTH)

        {
          key: trimmed_key,
          value: trimmed_value
        }
      end

      formatted_tags.compact
    end

    def self.tag_specifications_for_resources(tags_hash, resource_types)
      return [] if tags_hash.nil? || tags_hash.empty?

      formatted = format_tags(tags_hash)
      return [] if formatted.empty?

      Array(resource_types).map { |rt| { resource_type: rt, tags: formatted } }
    end
  end
end

# frozen_string_literal: true

# name: discourse-ai-detector
# about: Estimates how likely a post is to be AI-generated, using Claude
# version: 0.2.0
# authors: Judith Meyer
# url: https://github.com/sprachprofi/discourse-ai-detector

enabled_site_setting :ai_detector_enabled

# Discourse installs plugin gems one at a time without resolving dependencies,
# so every dependency of the anthropic gem that Discourse doesn't already
# bundle has to be listed here, before the gem itself. (base64,
# connection_pool and logger come from Discourse.)
gem "opentelemetry-api", "1.11.1", require: false
gem "standardwebhooks", "1.3.0", require: false
gem "anthropic", "2.12.0", require: false

register_asset "stylesheets/ai-detector.scss"
register_svg_icon "robot"

module ::DiscourseAiDetector
  PLUGIN_NAME = "discourse-ai-detector"

  PROBABILITY_FIELD = "ai_detector_probability"
  REASONING_FIELD = "ai_detector_reasoning"
  # Hash of the text that was scored, so unchanged edits aren't re-checked.
  DIGEST_FIELD = "ai_detector_digest"
end

require_relative "lib/discourse_ai_detector/checker"

after_initialize do
  require_relative "lib/discourse_ai_detector/post_checker"
  require_relative "app/jobs/regular/ai_detector_check_post"

  module ::DiscourseAiDetector
    # Only ordinary posts by regular users in public topics outside the
    # excluded categories. Private messages are never sent to Anthropic.
    def self.checkable?(post)
      post.present? && post.deleted_at.nil? && post.user_id.to_i > 0 &&
        post.post_type == Post.types[:regular] && post.topic.present? &&
        !post.topic.private_message? && !post.user&.staff? &&
        !excluded_category?(post.topic.category)
    end

    # Excluding a category also excludes its subcategories.
    def self.excluded_category?(category)
      return false if category.nil?
      excluded = SiteSetting.ai_detector_excluded_categories.to_s.split("|").map(&:to_i)
      excluded.include?(category.id) || excluded.include?(category.parent_category_id)
    end

    def self.flagged?(probability)
      probability.present? && probability.to_i >= SiteSetting.ai_detector_threshold
    end
  end

  register_post_custom_field_type(DiscourseAiDetector::PROBABILITY_FIELD, :integer)
  register_post_custom_field_type(DiscourseAiDetector::REASONING_FIELD, :string)
  register_post_custom_field_type(DiscourseAiDetector::DIGEST_FIELD, :string)

  on(:post_created) do |post|
    if DiscourseAiDetector.checkable?(post)
      Jobs.enqueue(:ai_detector_check_post, post_id: post.id)
    end
  end

  # Wait a minute after an edit so a burst of quick edits costs one check: the
  # later jobs see the same text as the first and skip it.
  on(:post_edited) do |post|
    if DiscourseAiDetector.checkable?(post)
      Jobs.enqueue_in(1.minute, :ai_detector_check_post, post_id: post.id)
    end
  end

  # Load the fields with the topic's posts in one query instead of one per post.
  topic_view_post_custom_fields_allowlister do |user|
    fields = [DiscourseAiDetector::PROBABILITY_FIELD]
    fields << DiscourseAiDetector::REASONING_FIELD if user&.staff?
    fields
  end

  # Everyone sees the score, but only when it's at or above the threshold.
  # Scores are stored raw, so changing the threshold applies to old posts too.
  add_to_serializer(
    :post,
    :ai_detector_probability,
    include_condition: -> do
      DiscourseAiDetector.flagged?(post_custom_fields[DiscourseAiDetector::PROBABILITY_FIELD])
    end,
  ) { post_custom_fields[DiscourseAiDetector::PROBABILITY_FIELD].to_i }

  # Claude's explanation is for moderators only.
  add_to_serializer(
    :post,
    :ai_detector_reasoning,
    include_condition: -> do
      scope.is_staff? &&
        DiscourseAiDetector.flagged?(post_custom_fields[DiscourseAiDetector::PROBABILITY_FIELD])
    end,
  ) { post_custom_fields[DiscourseAiDetector::REASONING_FIELD] }
end

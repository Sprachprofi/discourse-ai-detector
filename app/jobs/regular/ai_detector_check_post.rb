# frozen_string_literal: true

module ::Jobs
  # Scores one post with Claude in the background (see PostChecker).
  class AiDetectorCheckPost < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(args)
      return unless SiteSetting.ai_detector_enabled
      return if SiteSetting.ai_detector_anthropic_api_key.blank?

      post = Post.find_by(id: args[:post_id])
      DiscourseAiDetector::PostChecker.new.call(post) if post
    rescue DiscourseAiDetector::Checker::Error,
           Anthropic::Errors::AuthenticationError,
           Anthropic::Errors::PermissionDeniedError,
           Anthropic::Errors::BadRequestError => e
      # Retrying won't help with these. Rate limits, timeouts and server errors
      # are raised instead, so Sidekiq retries them later.
      Rails.logger.warn("[discourse-ai-detector] post #{args[:post_id]}: #{e.class}: #{e.message}")
    end
  end
end

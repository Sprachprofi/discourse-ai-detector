# frozen_string_literal: true

module ::DiscourseAiDetector
  # Scores one post and stores the result in its custom fields. Shared by the
  # background job and the rake task. Needs Discourse loaded.
  class PostChecker
    Outcome = Struct.new(:status, :result, keyword_init: true)
    # status: :skipped (not a post we check), :unchanged (this text was already
    # scored), :empty (nothing but quotes), :checked (result is set)

    def initialize(checker = nil)
      @checker = checker
    end

    def call(post)
      return Outcome.new(status: :skipped) unless DiscourseAiDetector.checkable?(post)

      text = Checker.strip_quotes(post.raw)
      digest = Digest::SHA256.hexdigest(text)
      return Outcome.new(status: :unchanged) if post.custom_fields[DIGEST_FIELD] == digest

      was_flagged = DiscourseAiDetector.flagged?(post.custom_fields[PROBABILITY_FIELD])

      result = checker.check(text)
      post.custom_fields[DIGEST_FIELD] = digest
      if result
        post.custom_fields[PROBABILITY_FIELD] = result.probability
        post.custom_fields[REASONING_FIELD] = result.reasoning
      else
        # Nothing but quotes left after an edit: drop any old score.
        post.custom_fields.delete(PROBABILITY_FIELD)
        post.custom_fields.delete(REASONING_FIELD)
      end
      post.save_custom_fields(true)

      # Make open topic pages reload the post if the banner should appear or go.
      if was_flagged || DiscourseAiDetector.flagged?(result&.probability)
        post.publish_change_to_clients!(:revised)
      end

      Outcome.new(status: result ? :checked : :empty, result: result)
    end

    private

    def checker
      @checker ||= Checker.new(
        api_key: SiteSetting.ai_detector_anthropic_api_key,
        model: SiteSetting.ai_detector_model.presence || Checker::DEFAULT_MODEL,
      )
    end
  end
end

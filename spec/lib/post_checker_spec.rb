# frozen_string_literal: true

# Runs inside Discourse: LOAD_PLUGINS=1 bin/rspec plugins/discourse-ai-detector/spec/lib/post_checker_spec.rb
RSpec.describe DiscourseAiDetector::PostChecker do
  fab!(:post) { Fabricate(:post, raw: "This is a post written by a person, honestly.") }

  let(:checker) { instance_double(DiscourseAiDetector::Checker) }
  let(:result) { DiscourseAiDetector::Checker::Result.new(probability: 85, reasoning: "Generic tone") }

  before do
    SiteSetting.ai_detector_anthropic_api_key = "sk-test"
    allow(checker).to receive(:check).and_return(result)
  end

  describe "dry run" do
    it "returns the score without saving anything" do
      outcome = described_class.new(checker).call(post, dry_run: true)

      expect(outcome.status).to eq(:checked)
      expect(outcome.result.probability).to eq(85)
      post.reload
      expect(post.custom_fields["ai_detector_probability"]).to be_nil
      expect(post.custom_fields["ai_detector_reasoning"]).to be_nil
      expect(post.custom_fields["ai_detector_digest"]).to be_nil
    end

    it "scores the same text again next time" do
      expect(checker).to receive(:check).twice.and_return(result)

      2.times { described_class.new(checker).call(post, dry_run: true) }
    end
  end

  it "uses an API key passed in instead of the site setting" do
    expect(DiscourseAiDetector::Checker).to receive(:new)
      .with(hash_including(api_key: "sk-from-env")).and_return(checker)

    described_class.new(api_key: "sk-from-env").call(post, dry_run: true)
  end

  it "saves the score on a normal run" do
    described_class.new(checker).call(post)

    expect(post.reload.custom_fields["ai_detector_probability"]).to eq(85)
  end
end

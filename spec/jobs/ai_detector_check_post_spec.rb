# frozen_string_literal: true

# Runs inside Discourse: LOAD_PLUGINS=1 bin/rspec plugins/discourse-ai-detector/spec/jobs
RSpec.describe Jobs::AiDetectorCheckPost do
  fab!(:post) { Fabricate(:post, raw: "This is a post written by a person, honestly.") }

  let(:checker) { instance_double(DiscourseAiDetector::Checker) }
  let(:result) do
    DiscourseAiDetector::Checker::Result.new(probability: 85, reasoning: "Uses 'not just X, it's Y'")
  end

  before do
    SiteSetting.ai_detector_enabled = true
    SiteSetting.ai_detector_anthropic_api_key = "sk-test"
    allow(DiscourseAiDetector::Checker).to receive(:new).and_return(checker)
  end

  it "stores the score and reasoning" do
    allow(checker).to receive(:check).and_return(result)

    described_class.new.execute(post_id: post.id)

    post.reload
    expect(post.custom_fields["ai_detector_probability"]).to eq(85)
    expect(post.custom_fields["ai_detector_reasoning"]).to eq("Uses 'not just X, it's Y'")
  end

  it "does not re-check unchanged text" do
    expect(checker).to receive(:check).once.and_return(result)

    described_class.new.execute(post_id: post.id)
    described_class.new.execute(post_id: post.id)
  end

  it "skips private messages" do
    pm = Fabricate(:private_message_post)
    expect(checker).not_to receive(:check)

    described_class.new.execute(post_id: pm.id)
  end

  it "skips posts by moderators" do
    staff_post = Fabricate(:post, user: Fabricate(:moderator))
    expect(checker).not_to receive(:check)

    described_class.new.execute(post_id: staff_post.id)
  end

  it "skips posts in excluded categories and their subcategories" do
    parent = Fabricate(:category)
    child = Fabricate(:category, parent_category: parent)
    SiteSetting.ai_detector_excluded_categories = parent.id.to_s
    child_post = Fabricate(:post, topic: Fabricate(:topic, category: child))
    expect(checker).not_to receive(:check)

    described_class.new.execute(post_id: child_post.id)
  end

  it "logs and gives up when Claude's reply is unusable" do
    allow(checker).to receive(:check).and_raise(DiscourseAiDetector::Checker::Error, "declined")

    expect { described_class.new.execute(post_id: post.id) }.not_to raise_error
    expect(post.reload.custom_fields["ai_detector_probability"]).to be_nil
  end

  describe "serializer" do
    before do
      post.custom_fields["ai_detector_probability"] = 80
      post.custom_fields["ai_detector_reasoning"] = "reason"
      post.save_custom_fields(true)
    end

    def serialize(user)
      PostSerializer.new(post.reload, scope: Guardian.new(user), root: false).as_json
    end

    it "shows the score to everyone but the reasoning only to staff" do
      expect(serialize(Fabricate(:user))[:ai_detector_probability]).to eq(80)
      expect(serialize(Fabricate(:user))).not_to have_key(:ai_detector_reasoning)
      expect(serialize(Fabricate(:moderator))[:ai_detector_reasoning]).to eq("reason")
    end

    it "hides scores below the threshold" do
      SiteSetting.ai_detector_threshold = 90
      expect(serialize(Fabricate(:user))).not_to have_key(:ai_detector_probability)
    end
  end
end

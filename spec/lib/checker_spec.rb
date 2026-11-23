# frozen_string_literal: true

require_relative "../../lib/discourse_ai_detector/checker"

RSpec.describe DiscourseAiDetector::Checker do
  TextBlock = Struct.new(:type, :text)
  Usage = Struct.new(:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_creation_input_tokens)
  FakeMessage = Struct.new(:content, :stop_reason, :stop_details, :model, :usage)

  let(:messages) { double("messages") }
  let(:client) { double("client", beta: double("beta", messages: messages)) }
  let(:checker) { described_class.new(api_key: "unused", client: client) }

  def reply(json, stop_reason: :end_turn)
    FakeMessage.new([TextBlock.new(:text, json)], stop_reason, nil, :"claude-opus-5-5", Usage.new(100, 20))
  end

  it "returns the probability and reasoning" do
    allow(messages).to receive(:create).and_return(reply('{"reasoning":"Generic tone","probability":92}'))

    result = checker.check("Some post")

    expect(result.probability).to eq(92)
    expect(result.reasoning).to eq("Generic tone")
  end

  it "wraps the post in <post> tags and asks for structured output" do
    expect(messages).to receive(:create) do |params|
      expect(params[:model]).to eq("claude-opus-5-5")
      expect(params[:messages].first[:content]).to eq("<post>\nHello\n</post>")
      expect(params[:output_config][:format_][:type]).to eq(:json_schema)
      reply('{"reasoning":"x","probability":5}')
    end

    checker.check("  Hello  ")
  end

  it "clamps out-of-range probabilities" do
    allow(messages).to receive(:create).and_return(reply('{"reasoning":"x","probability":140}'))
    expect(checker.check("text").probability).to eq(100)
  end

  it "skips blank text without calling the API" do
    expect(messages).not_to receive(:create)
    expect(checker.check("   ")).to be_nil
  end

  it "raises on refusal" do
    allow(messages).to receive(:create).and_return(reply("", stop_reason: :refusal))
    expect { checker.check("text") }.to raise_error(described_class::Error, /declined/)
  end

  it "raises on truncated output" do
    allow(messages).to receive(:create).and_return(reply('{"reasoning":"x', stop_reason: :max_tokens))
    expect { checker.check("text") }.to raise_error(described_class::Error, /max_tokens/)
  end
end

RSpec.describe DiscourseAiDetector::Checker, ".strip_quotes" do
  it "removes Discourse quote blocks and Markdown quote lines" do
    raw = "[quote=\"bob, post:3\"]\nTheir words\n[/quote]\nMy reply\n> quoted line\nMore of mine"
    expect(described_class.strip_quotes(raw)).to eq("My reply\nMore of mine")
  end

  it "returns nil from check when the post is only a quote" do
    checker = described_class.new(api_key: "x", client: double("client"))
    expect(checker.check("[quote]all quoted[/quote]")).to be_nil
  end
end

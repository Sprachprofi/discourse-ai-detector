# frozen_string_literal: true

# Runs the AI-text check outside Discourse.
#
#   ANTHROPIC_API_KEY=sk-ant-... ruby script/check.rb "some text"
#   ruby script/check.rb path/to/post.txt [another.txt ...]
#   echo "some text" | ruby script/check.rb
#
# Optional: AI_DETECTOR_MODEL=claude-sonnet-5-5

require_relative "../lib/discourse_ai_detector/checker"

api_key = ENV["ANTHROPIC_API_KEY"]
abort "Set ANTHROPIC_API_KEY first." if api_key.to_s.empty?

inputs =
  if ARGV.empty?
    [["stdin", $stdin.read]]
  else
    ARGV.map { |arg| File.file?(arg) ? [arg, File.read(arg)] : ["argument", arg] }
  end

checker = DiscourseAiDetector::Checker.new(
  api_key: api_key,
  model: ENV.fetch("AI_DETECTOR_MODEL", DiscourseAiDetector::Checker::DEFAULT_MODEL)
)

inputs.each do |label, text|
  puts "== #{label}"
  result = checker.check(text)
  if result.nil?
    puts "(empty text, skipped)"
  else
    flag = result.probability >= 75 ? "  <-- would show warning banner" : ""
    puts "AI probability: #{result.probability}%#{flag}"
    puts "Reasoning:      #{result.reasoning}"
    puts "Tokens:         #{result.input_tokens} in / #{result.output_tokens} out (#{result.model})"
  end
rescue DiscourseAiDetector::Checker::Error, Anthropic::Errors::APIError => e
  puts "ERROR: #{e.class}: #{e.message}"
end

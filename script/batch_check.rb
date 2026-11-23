# frozen_string_literal: true

# Scores every post in a test file and writes the results as JSON.
#
#   ANTHROPIC_API_KEY=sk-ant-... ruby script/batch_check.rb discourse_posts_test.txt results.json
#
# Input format: posts separated by a line of dashes; each post starts with its URL line.

require "json"
require_relative "../lib/discourse_ai_detector/checker"

input, output = ARGV
abort "Usage: ruby script/batch_check.rb INPUT.txt OUTPUT.json" unless input && output
abort "Set ANTHROPIC_API_KEY first." if ENV["ANTHROPIC_API_KEY"].to_s.empty?

posts = File.read(input).split(/^-{10,}\s*$/).map(&:strip).reject(&:empty?).map do |chunk|
  url, body = chunk.split("\n", 2)
  { url: url.strip, text: body.to_s.strip }
end

checker = DiscourseAiDetector::Checker.new(api_key: ENV["ANTHROPIC_API_KEY"])

results = posts.each_with_index.map do |post, i|
  print "\r#{i + 1}/#{posts.size}"
  begin
    r = checker.check(post[:text])
    post.merge(probability: r&.probability, reasoning: r&.reasoning,
               input_tokens: r&.input_tokens, output_tokens: r&.output_tokens,
               cache_read_tokens: r&.cache_read_tokens, cache_write_tokens: r&.cache_write_tokens)
  rescue DiscourseAiDetector::Checker::Error, Anthropic::Errors::APIError => e
    post.merge(error: "#{e.class}: #{e.message}")
  end
end
puts

File.write(output, JSON.pretty_generate(results))
results.each do |r|
  score = r[:error] ? "ERR " : format("%3d%%%s", r[:probability].to_i, r[:probability].to_i >= 75 ? "*" : " ")
  puts "#{score}  #{r[:url]}"
end
# Claude Opus 5.5 prices per million tokens; cache writes are 1.25x input.
PRICES = { input: 4.0, output: 20.0, cache_read: 0.20, cache_write: 4.0 * 1.25 }.freeze
ok = results.reject { |r| r[:error] || r[:probability].nil? }
unless ok.empty?
  sum = ->(k) { ok.sum { |r| r[k].to_i } }
  cost = (sum.(:input_tokens) * PRICES[:input] + sum.(:output_tokens) * PRICES[:output] +
          sum.(:cache_read_tokens) * PRICES[:cache_read] + sum.(:cache_write_tokens) * PRICES[:cache_write]) / 1_000_000
  puts format("Tokens per post (avg): %d input, %d cache read, %d cache write, %d output",
              sum.(:input_tokens) / ok.size, sum.(:cache_read_tokens) / ok.size,
              sum.(:cache_write_tokens) / ok.size, sum.(:output_tokens) / ok.size)
  puts format("Cost: $%.4f total, $%.4f per post (Opus 5.5 prices)", cost, cost / ok.size)
end
puts "* = would show the banner (>= 75%)"
puts "Wrote #{output}"

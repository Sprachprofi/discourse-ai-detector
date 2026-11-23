# frozen_string_literal: true

# Checks the most recent posts right away, printing each score. Run from the
# Discourse directory (inside the container: cd /var/www/discourse):
#
#   bin/rake "ai_detector:check_latest[100]"
#
# Posts that wouldn't be checked automatically (PMs, staff posts, excluded
# categories, ...) are passed over and don't count toward the number. Posts
# whose text was already scored are counted but not sent again, so re-running
# the task is cheap. Works even while ai_detector_enabled is off, so admins
# can try it before showing banners.
desc "Check the latest N posts for AI-generated text (default 50)"
task "ai_detector:check_latest", [:count] => :environment do |_, args|
  count = (args[:count] || 50).to_i
  abort "Count must be a positive number" unless count.positive?
  abort "Set the ai_detector_anthropic_api_key site setting first" if SiteSetting.ai_detector_anthropic_api_key.blank?

  unless SiteSetting.ai_detector_enabled
    puts "Note: ai_detector_enabled is off, so scores are stored but no banners show yet."
  end

  base_url = Discourse.base_url
  threshold = SiteSetting.ai_detector_threshold
  checker = DiscourseAiDetector::PostChecker.new
  counts = Hash.new(0)
  tokens = Hash.new(0)
  seen = 0

  # The SQL narrows things down; checkable? makes the final decision.
  candidates =
    Post
      .joins(:topic)
      .where(post_type: Post.types[:regular], deleted_at: nil)
      .where("posts.user_id > 0")
      .where(topics: { archetype: Archetype.default, deleted_at: nil })
      .includes(:user, topic: :category)
      .order(id: :desc)

  # Walk backwards through post ids a page at a time; loading the whole
  # ordered table at once would be far too much on a big forum.
  batches = Enumerator.new do |y|
    last_id = nil
    loop do
      page = (last_id ? candidates.where("posts.id < ?", last_id) : candidates).limit(200).to_a
      break if page.empty?
      page.each { |post| y << post }
      last_id = page.last.id
    end
  end

  batches.each do |post|
    break if seen >= count
    next unless DiscourseAiDetector.checkable?(post)
    seen += 1

    label = "#{base_url}/p/#{post.id}"
    begin
      outcome = checker.call(post)
    rescue DiscourseAiDetector::Checker::Error, Anthropic::Errors::APIError => e
      counts[:error] += 1
      puts format("  ERR  %s  %s", label, e.message.to_s.lines.first&.strip)
      next
    end

    counts[outcome.status] += 1
    case outcome.status
    when :checked
      r = outcome.result
      flagged = r.probability >= threshold
      counts[:flagged] += 1 if flagged
      %i[input_tokens output_tokens cache_read_tokens cache_write_tokens].each { |k| tokens[k] += r[k].to_i }
      puts format("%4d%%%s %s", r.probability, flagged ? "*" : " ", label)
    when :unchanged
      puts format("  --   %s  (already checked)", label)
    when :empty
      puts format("  --   %s  (only quotes)", label)
    end
  end

  puts
  puts "#{seen} posts: #{counts[:checked]} checked, #{counts[:unchanged]} already checked, " \
       "#{counts[:empty]} only quotes, #{counts[:error]} errors"
  puts "#{counts[:flagged]} at or above #{threshold}% (marked *)"
  if counts[:checked].positive?
    puts "Tokens: #{tokens[:input_tokens]} input, #{tokens[:cache_read_tokens]} cache read, " \
         "#{tokens[:cache_write_tokens]} cache write, #{tokens[:output_tokens]} output"
  end
end

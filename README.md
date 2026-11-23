# discourse-ai-detector

A Discourse plugin that asks Claude how likely each new post is to be
AI-generated. Posts that score at or above a threshold (75% by default) get a
warning banner above the text:

> 🤖 An automated check estimates a 85% chance that this post was written by
> AI. The check can be wrong.

Staff can expand the banner to see Claude's reasoning, for example which
typical AI phrasings it found.

The score is an estimate, not proof. Treat a banner as a prompt to read more
carefully, not as a verdict on the author.

## How it works

1. When a post is created, or its text changes on edit, a background job sends
   the post text to the Claude API. Quoted text (`[quote]` blocks and `>`
   lines) is removed first, so quoting an AI-written post doesn't count
   against the person quoting it.
2. Claude compares the text against a list of known signs of AI writing,
   based on Wikipedia's
   [Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing),
   and against signs of human writing. It returns a score from 0 to 100 and a
   short explanation. Non-native grammar is explicitly not treated as a sign
   of AI.
3. The score and explanation are stored on the post. Readers who have the
   topic open see the banner appear without reloading.

Posting is never slowed down or blocked: the check runs afterwards, and if it
fails the post simply has no banner.

### What gets checked

- New posts in public topics.
- Edited posts, 10 minutes after the edit, but only if the text actually
  changed. An author who keeps revising is checked on their final text.

Not checked:

- Private messages. These are never sent to Anthropic.
- Posts by admins and moderators.
- Posts in excluded categories (see settings).
- Whispers, small-action posts, and posts by system or bot users.
- Posts written before the plugin was enabled (use the rake task below).

## Installation

Follow Discourse's
[plugin install guide](https://meta.discourse.org/t/install-plugins-in-discourse/19157):
add the repository to `app.yml`

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/sprachprofi/discourse-ai-detector.git
```

then rebuild:

```
cd /var/discourse
./launcher rebuild app
```

You need an Anthropic API key from
[console.anthropic.com](https://console.anthropic.com/).

The plugin uses Discourse's current post-stream outlet
(`post-content-cooked-html`). On older Discourse versions the check still
runs, but the banner may not appear.

## Settings

Admin → Settings → Plugins:

| Setting | Default | |
|---|---|---|
| `ai_detector_enabled` | off | Turns the checks and banners on. |
| `ai_detector_anthropic_api_key` | | Required. |
| `ai_detector_model` | `claude-opus-5-5` | Any Claude model ID. Cheaper models were noticeably less accurate in testing. |
| `ai_detector_threshold` | 75 | The banner shows at or above this percentage. Scores are stored raw, so changing this applies to posts already checked. |
| `ai_detector_banner_text` | blank | Custom banner text. `{probability}` is replaced by the score, e.g. `This post looks {probability}% AI-written.` Plain text only. Blank uses the built-in, translatable text. |
| `ai_detector_excluded_categories` | none | Posts in these categories and their subcategories aren't checked. |

Two things these settings don't change after the fact. Excluding a category
or promoting a user to moderator doesn't remove banners from posts that were
already flagged, and moving a topic into an excluded category keeps its
existing banners.

The "Why? (visible to staff only)" label can be changed under Admin →
Customize → Text (`ai_detector.reasoning_staff`).

## Checking existing posts

Admins can score the most recent posts right away over SSH. This also works
for posts written before the plugin was installed:

```
cd /var/discourse
./launcher enter app
cd /var/www/discourse
su discourse -c 'bundle exec rake "ai_detector:check_latest[100]"'
```

Leaving out the number checks 50 posts. The task prints each post's score and
link, marking those at or above the threshold with `*`, then totals and token
usage:

```
  85%* https://forum.example.org/p/1234
  12%  https://forum.example.org/p/1233
  --   https://forum.example.org/p/1232  (already checked)
```

- Posts the plugin wouldn't check (PMs, staff posts, excluded categories) are
  passed over and don't count toward the number.
- Posts whose text was already scored aren't sent again, so re-running the
  task costs little. To go further back, give a bigger number.
- It works while `ai_detector_enabled` is off, so you can look at the scores
  before any banners appear.
- An error on one post is shown as `ERR` and the task carries on.

### Dry run

To try the detector without touching the forum, add `dry_run`:

```
su discourse -c 'bundle exec rake "ai_detector:check_latest[100,dry_run]"'
```

The posts are scored and printed as usual, but nothing is saved: no banners
appear or change, and running the task again later scores the same posts
again. Each post is still sent to Claude, so a dry run costs the same as a
normal one. Posts that were already scored in an earlier normal run are
passed over as `(already checked)`.

To try it before saving an API key in the admin settings, or with a different
key, pass one in `ANTHROPIC_API_KEY`. It takes the place of the site setting
for this run only:

```
su discourse -c 'ANTHROPIC_API_KEY=sk-ant-... bundle exec rake "ai_detector:check_latest[20,dry_run]"'
```

The key ends up in your shell history. Run `history -c` afterwards, or start
the line with a space if your shell has `HISTCONTROL=ignorespace` set.

## Cost

Measured on 50 real forum posts with Claude Opus 5.5:

```
Cost: $0.3074 total, $0.0061 per post (Opus 5.5 prices)
```

That is about 0.6 cents per post, or roughly $6 per 1,000 posts. Most of the
cost is Claude's reasoning before it answers. The instructions are cached, so
the cost is a little lower when posts arrive within a few minutes of each
other.

## Privacy

The text of each checked post is sent to Anthropic's API. The author's name,
the topic and the category are not. Private messages are never sent. The API
key is stored as a secret site setting and is never sent to browsers.

Everyone sees the score on flagged posts. Only staff see Claude's reasoning,
and scores below the threshold aren't sent to browsers at all.

## Troubleshooting

- **No banners:** check that `ai_detector_enabled` is on and the API key is
  set, and that the post isn't by staff, in a PM, or in an excluded category.
  Run the rake task on a few posts to see their scores.
- **Errors:** failed checks are written to the Discourse log (`/logs`) with the
  prefix `[discourse-ai-detector]`. Rate limits, timeouts and Anthropic
  outages are retried automatically by Sidekiq. A wrong API key or a post
  Claude declines to classify is logged once and not retried.

## Development

The Claude call lives in `lib/discourse_ai_detector/checker.rb`, which is
plain Ruby and can be run without Discourse:

```
gem install anthropic -v 2.12.0
ANTHROPIC_API_KEY=sk-ant-... ruby script/check.rb "some text"
ANTHROPIC_API_KEY=sk-ant-... ruby script/check.rb samples/ai.txt samples/human.txt
ANTHROPIC_API_KEY=sk-ant-... ruby script/batch_check.rb posts.txt results.json
```

`batch_check.rb` reads posts separated by lines of dashes, with each post's
URL on its first line. It prints every score and the total cost.

Tests:

```
rspec spec/lib                                                   # standalone
LOAD_PLUGINS=1 bin/rspec plugins/discourse-ai-detector/spec      # inside a Discourse checkout
```

| File | |
|---|---|
| `plugin.rb` | Settings, event hooks, what's sent to the browser |
| `lib/discourse_ai_detector/checker.rb` | The prompt and the Claude API call |
| `lib/discourse_ai_detector/post_checker.rb` | Scores one post and stores the result |
| `app/jobs/regular/ai_detector_check_post.rb` | Background job |
| `lib/tasks/ai_detector.rake` | `ai_detector:check_latest` |
| `assets/javascripts/discourse/components/ai-detector-banner.gjs` | The banner |

## License

MIT, see [LICENSE](LICENSE).

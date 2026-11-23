import Component from "@glimmer/component";
import { service } from "@ember/service";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

// Shown above a post's text when the server says its AI score is at or above
// the threshold. The server only sends ai_detector_probability in that case.
export default class AiDetectorBanner extends Component {
  @service siteSettings;

  get post() {
    return this.args.outletArgs.post;
  }

  get show() {
    const probability = this.post?.ai_detector_probability;
    return (
      this.siteSettings.ai_detector_enabled &&
      probability != null &&
      probability >= this.siteSettings.ai_detector_threshold
    );
  }

  // The admin-set text, with {probability} replaced by the score. Falls back
  // to the translated default when the setting is blank.
  get message() {
    const probability = this.post.ai_detector_probability;
    const custom = this.siteSettings.ai_detector_banner_text?.trim();
    if (!custom) {
      return i18n("ai_detector.banner", { probability });
    }
    return custom.replaceAll("{probability}", probability);
  }

  <template>
    {{#if this.show}}
      <div class="ai-detector-banner" role="note">
        <div class="ai-detector-banner__message">
          {{dIcon "robot"}}
          <span>{{this.message}}</span>
        </div>
        {{#if this.post.ai_detector_reasoning}}
          <details class="ai-detector-banner__reasoning">
            <summary>{{i18n "ai_detector.reasoning_staff"}}</summary>
            <p>{{this.post.ai_detector_reasoning}}</p>
          </details>
        {{/if}}
      </div>
    {{/if}}
  </template>
}

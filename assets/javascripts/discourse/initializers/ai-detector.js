import { withPluginApi } from "discourse/lib/plugin-api";
import AiDetectorBanner from "../components/ai-detector-banner";

export default {
  name: "ai-detector",

  initialize(container) {
    if (!container.lookup("service:site-settings").ai_detector_enabled) {
      return;
    }

    withPluginApi((api) => {
      // Lets the banner update when the post is reloaded after the check.
      api.addTrackedPostProperties(
        "ai_detector_probability",
        "ai_detector_reasoning"
      );
      api.renderBeforeWrapperOutlet(
        "post-content-cooked-html",
        AiDetectorBanner
      );
    });
  },
};

import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { pushState } from "./src/push-state.js";

const DEFAULT_STATE_FILE = "/data/star-office/state.json";

const plugin = {
  id: "star-office",
  name: "Star Office UI",
  description: "Push agent state to a Star Office pixel-art dashboard",

  register(api: OpenClawPluginApi) {
    const cfg = api.pluginConfig as { url?: string; stateFile?: string } | undefined;
    const targets: string[] = [];
    if (cfg?.stateFile) targets.push(cfg.stateFile);
    if (cfg?.url) targets.push(cfg.url);
    if (targets.length === 0) targets.push(DEFAULT_STATE_FILE);

    const log = api.logger;
    log.info(`[star-office] Pushing state to: ${targets.join(", ")}`);

    function push(state: string, detail: string) {
      for (const t of targets) pushState(t, state, detail, log);
    }

    api.on("before_agent_start", () => { push("writing", "Thinking..."); return undefined; });
    api.on("before_tool_call", (event) => { push("executing", `Running tool: ${event.toolName}`); return undefined; });
    api.on("agent_end", () => { push("idle", "Done"); });
    api.on("session_start", () => { push("syncing", "Session started"); });
    api.on("session_end", () => { push("idle", "Session ended"); });
  },
};

export default plugin;

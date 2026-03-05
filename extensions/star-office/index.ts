import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { request as httpRequest } from "node:http";
import { pushState } from "./src/push-state.js";

const DEFAULT_STATE_FILE = "/data/star-office/state.json";
const STAR_OFFICE_PORT = Number(process.env.STAR_OFFICE_PORT) || 18791;

const plugin = {
  id: "star-office",
  name: "Star Office UI",
  description: "Push agent state to a Star Office pixel-art dashboard",

  register(api: OpenClawPluginApi) {
    const cfg = api.pluginConfig as { url?: string; stateFile?: string } | undefined;
    const target = cfg?.url ?? cfg?.stateFile ?? DEFAULT_STATE_FILE;
    const log = api.logger;
    log.info(`[star-office] Pushing state to: ${target}`);

    // Reverse proxy: /star-office/* → local Star Office backend
    api.registerHttpHandler(async (req, res) => {
      const url = req.url ?? "/";
      if (!url.startsWith("/star-office")) return false;

      const upstreamPath = url.replace(/^\/star-office/, "") || "/";

      return new Promise<boolean>((resolve) => {
        const proxyReq = httpRequest(
          {
            hostname: "127.0.0.1",
            port: STAR_OFFICE_PORT,
            path: upstreamPath,
            method: req.method,
            headers: { ...req.headers, host: `127.0.0.1:${STAR_OFFICE_PORT}` },
          },
          (proxyRes) => {
            res.writeHead(proxyRes.statusCode ?? 502, proxyRes.headers);
            proxyRes.pipe(res);
            proxyRes.on("end", () => resolve(true));
          },
        );

        proxyReq.on("error", (err) => {
          log.warn(`[star-office] proxy error: ${String(err)}`);
          res.writeHead(502, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "Star Office backend unavailable" }));
          resolve(true);
        });

        req.pipe(proxyReq);
      });
    });

    // Hook: agent starts → "writing"
    api.on("before_agent_start", (_event, _ctx) => {
      pushState(target, "writing", "Thinking...", log);
      return undefined;
    });

    // Hook: tool call → "executing"
    api.on("before_tool_call", (event, _ctx) => {
      pushState(target, "executing", `Running tool: ${event.toolName}`, log);
      return undefined;
    });

    // Hook: agent done → "idle"
    api.on("agent_end", (_event, _ctx) => {
      pushState(target, "idle", "Done", log);
    });

    // Hook: session start → "syncing"
    api.on("session_start", (_event, _ctx) => {
      pushState(target, "syncing", "Session started", log);
    });

    // Hook: session end → "idle"
    api.on("session_end", (_event, _ctx) => {
      pushState(target, "idle", "Session ended", log);
    });
  },
};

export default plugin;

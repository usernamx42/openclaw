import { writeFileSync, readFileSync, existsSync } from "node:fs";

const VALID_STATES = new Set(["idle", "writing", "researching", "executing", "syncing", "error"]);

/**
 * Write agent state directly to Star Office state.json file.
 * Falls back to HTTP POST if a URL is configured instead of a file path.
 */
export function pushState(
  target: string,
  state: string,
  detail: string,
  logger?: { warn: (msg: string) => void },
): void {
  if (!VALID_STATES.has(state)) return;

  // If target looks like a URL, use HTTP
  if (target.startsWith("http://") || target.startsWith("https://")) {
    const url = `${target.replace(/\/+$/, "")}/set_state`;
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ state, detail }),
      signal: AbortSignal.timeout(5000),
    }).catch((err) => {
      logger?.warn(`[star-office] HTTP push failed: ${String(err)}`);
    });
    return;
  }

  // File-based: write directly to state.json
  try {
    const filePath = target;
    let current: Record<string, unknown> = {};
    if (existsSync(filePath)) {
      current = JSON.parse(readFileSync(filePath, "utf-8"));
    }
    current.state = state;
    current.detail = detail;
    current.updated_at = new Date().toISOString();
    writeFileSync(filePath, JSON.stringify(current, null, 2), "utf-8");
  } catch (err) {
    logger?.warn(`[star-office] file write failed: ${String(err)}`);
  }
}

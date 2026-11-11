// CORS for the functions the web app calls from a browser. Transport only: bodies, codes and auth
// are untouched. Requests with no Origin header (the iOS and macOS apps) pass through unchanged.

const DEFAULT_ORIGINS = ["https://flight.somalabs.me", "http://localhost:5173"];
const ALLOW_HEADERS = "authorization, x-client-info, apikey, content-type";
const ALLOW_METHODS = "GET, POST, DELETE, OPTIONS";

/** WEB_ORIGINS (comma list, spaces trimmed), or the production site and the local dev server. */
export function webOrigins(): string[] {
  const raw = Deno.env.get("WEB_ORIGINS");
  if (!raw) return [...DEFAULT_ORIGINS];
  const list = raw.split(",").map((s) => s.trim()).filter((s) => s !== "");
  return list.length > 0 ? list : [...DEFAULT_ORIGINS];
}

/**
 * Wraps a handler: answers an allowed origin's preflight with 204 (handler not called) and adds
 * Access-Control-Allow-Origin to its other answers. An origin outside the list gets no CORS header,
 * so the browser blocks the read; the status and body stay as they are.
 */
export function withCors(
  handler: (req: Request) => Response | Promise<Response>,
  origins?: string[],
): (req: Request) => Promise<Response> {
  return async (req) => {
    const origin = req.headers.get("origin");
    const allowed = origin !== null &&
      (origins ?? webOrigins()).includes(origin);
    if (allowed && req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": origin,
          "access-control-allow-headers": ALLOW_HEADERS,
          "access-control-allow-methods": ALLOW_METHODS,
          "access-control-max-age": "600",
          vary: "Origin",
        },
      });
    }
    const res = await handler(req);
    if (origin === null) return res;
    const out = new Response(res.body, res);
    out.headers.append("vary", "Origin");
    if (allowed) out.headers.set("access-control-allow-origin", origin);
    return out;
  };
}

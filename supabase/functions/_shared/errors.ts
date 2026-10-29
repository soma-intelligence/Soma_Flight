// Shared error type and JSON response helpers for edge functions.

export type ErrorCode =
  | "provider_unavailable"
  | "not_found"
  | "rate_limited"
  | "plan_limit"
  | "unauthorized";

export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly status: number;

  constructor(code: ErrorCode, status: number, message?: string) {
    super(message ?? code);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Body shape: { "error": { "code", "message" } }. Unknown errors become 500 provider_unavailable. */
export function errorResponse(e: unknown): Response {
  if (e instanceof ApiError) {
    return json({ error: { code: e.code, message: e.message } }, e.status);
  }
  console.error("unhandled error", e);
  return json(
    { error: { code: "provider_unavailable", message: "Internal error" } },
    500,
  );
}

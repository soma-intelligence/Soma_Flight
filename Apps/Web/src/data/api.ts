import { getSupabase } from "./client";

export type ApiErrorCode =
  | "unauthorized"
  | "invalid_request"
  | "not_found"
  | "rate_limited"
  | "plan_limit"
  | "out_of_window"
  | "provider_unavailable";

const CODES: readonly ApiErrorCode[] = [
  "unauthorized",
  "invalid_request",
  "not_found",
  "rate_limited",
  "plan_limit",
  "out_of_window",
  "provider_unavailable",
];

export class ApiError extends Error {
  code: ApiErrorCode;
  status: number;
  constructor(code: ApiErrorCode, status: number, message?: string) {
    super(message ?? code);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
  }
}

function bodyCode(body: unknown): { code: string; message?: string } | null {
  if (typeof body !== "object" || body === null) return null;
  const err = (body as { error?: unknown }).error;
  if (typeof err !== "object" || err === null) return null;
  const { code, message } = err as { code?: unknown; message?: unknown };
  if (typeof code !== "string") return null;
  return { code, message: typeof message === "string" ? message : undefined };
}

function codeFromStatus(status: number): ApiErrorCode {
  if (status === 401 || status === 403) return "unauthorized";
  if (status === 404) return "not_found";
  if (status === 429) return "rate_limited";
  return "provider_unavailable";
}

/** The body's `code` wins (unknown becomes provider_unavailable); a body that is not the backend's falls back on the status. */
export function apiErrorFrom(status: number, body: unknown): ApiError {
  const parsed = bodyCode(body);
  if (parsed) {
    const code = (CODES as readonly string[]).includes(parsed.code)
      ? (parsed.code as ApiErrorCode)
      : "provider_unavailable";
    return new ApiError(code, status, parsed.message);
  }
  return new ApiError(codeFromStatus(status), status);
}

export type CallInit = {
  method?: "GET" | "POST" | "DELETE";
  query?: Record<string, string>;
  body?: unknown;
};

export async function callFunction<T>(name: string, init: CallInit = {}): Promise<T> {
  const qs = init.query ? new URLSearchParams(init.query).toString() : "";
  const path = qs ? `${name}?${qs}` : name;
  const options: { method: "GET" | "POST" | "DELETE"; body?: unknown } = { method: init.method ?? "POST" };
  if (init.body !== undefined) options.body = init.body;
  const { data, error } = await getSupabase().functions.invoke(path, options as never);
  if (error) {
    const ctx = (error as { context?: unknown }).context;
    if (ctx instanceof Response) {
      let body: unknown = null;
      try {
        body = await ctx.json();
      } catch {
        body = null;
      }
      throw apiErrorFrom(ctx.status, body);
    }
    throw new ApiError("provider_unavailable", 0, error.message);
  }
  return data as T;
}

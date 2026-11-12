import type { ApiErrorCode } from "@/data/api";

/** The app's banner copy for an API error (APIError.message in FlightKit). */
export function errorCopy(code: ApiErrorCode | undefined): string {
  switch (code) {
    case "not_found":
      return "No flight found. Check the number and date.";
    case "out_of_window":
      return "Flights can be searched from 10 days back to 2 days ahead. Pick another date.";
    case "rate_limited":
      return "Too many searches. Try again in a few minutes.";
    case "plan_limit":
      return "You can follow up to 3 flights at a time.";
    case "unauthorized":
      return "Please sign in again.";
    default:
      return "Flight data is temporarily unavailable. Showing the last update.";
  }
}

/** The code of an ApiError-like value, if any. */
export function errorCode(e: unknown): ApiErrorCode | undefined {
  const c = (e as { code?: unknown } | null)?.code;
  return typeof c === "string" ? (c as ApiErrorCode) : undefined;
}

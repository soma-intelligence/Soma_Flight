// Favorite airport alerts: the program details faa's sweep for followed airports hands to push-sender,
// and the log key that makes each one go out once per user. No flight is involved, so alert_log (keyed
// by flight) is not used: favorite_alert_log (user_id, key) takes the claim.
//
// TODO(conditions): when faa-status exposes an airport "conditions" level (normal, minor, major), a
// move to major should become a second kind of favorite alert here (key `favorite_airport:<icao>:major:<hour>`),
// sent by the same sweep. This wave triggers on FAA programs only.
import { ALERT_KINDS, type ProgramKind } from "./faa_nas.ts";

/** What push-sender needs to word and claim one favorite airport push. */
export interface FavoriteAlert {
  user_id: string;
  /** favorite_alert_log key: `favorite:` plus the program's alert key. */
  key: string;
  kind: ProgramKind;
  /** The airport as the app shows it (IATA, else ICAO). */
  code: string;
  airport_icao: string;
  reason: string | null;
  average_minutes: number | null;
  ends_at: string | null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const text = (v: unknown, max = 200): string | null =>
  typeof v === "string" && v !== "" && v.length <= max ? v : null;

/** The fields push-sender needs, or null when `body` is not one (it came over the network). */
export function readFavoriteAlert(body: unknown): FavoriteAlert | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const o = body as Record<string, unknown>;
  const user = text(o.user_id), key = text(o.key, 160), code = text(o.code);
  const icao = text(o.airport_icao);
  if (!user || !UUID.test(user) || !key || !code || !icao) return null;
  if (!key.startsWith("favorite:airport_program:")) return null;
  if (!/^[A-Z0-9]{3,4}$/.test(code) || !/^[A-Z0-9]{4}$/.test(icao)) return null;
  const kind = o.kind as ProgramKind;
  if (!ALERT_KINDS.has(kind)) return null;
  const avg = typeof o.average_minutes === "number" &&
      Number.isFinite(o.average_minutes) && o.average_minutes >= 0
    ? Math.round(o.average_minutes)
    : null;
  const end = text(o.ends_at);
  return {
    user_id: user,
    key,
    kind,
    code,
    airport_icao: icao,
    reason: text(o.reason),
    average_minutes: avg,
    ends_at: end && Number.isFinite(Date.parse(end)) ? end : null,
  };
}

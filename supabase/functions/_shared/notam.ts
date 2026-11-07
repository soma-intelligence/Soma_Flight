// NOTAMs (notices to air missions) for an airport, from the FAA NOTAM API, put into plain English for
// the kinds a passenger can feel: runway, taxiway or airport closures, an ILS out of service, unlit
// obstacles and construction. Everything else (frequencies, procedures, airspace, birds) is left out.
//
// Source: the FAA NOTAM API (api.faa.gov portal, served from external-api.faa.gov/notamapi/v1). Free,
// but every call carries a client id and secret from an FAA developer account (FAA_NOTAM_CLIENT_ID,
// FAA_NOTAM_CLIENT_SECRET in the function's env). With either missing, faa-notams answers
// configured: false and the app hides its NOTAM rows; nothing here is called.
//
// decodeNotam is pure and reads the notice text alone, in the US domestic form
// ("!SFO 10/123 SFO RWY 10L/28R CLSD 2610301400-2610302200"), the bare body ("RWY 10L/28R CLSD") or the
// ICAO form (with "E) RWY 09L/27R CLSD DUE WIP."). A text it does not recognise is kind "other".

/** The kinds the app shows, from most to least felt by a passenger. */
export type NotamKind =
  | "airport_closed"
  | "runway_closed"
  | "ils_out"
  | "construction"
  | "taxiway_closed"
  | "obstacle_light";

export interface Decoded {
  kind: NotamKind | "other";
  /** "Runway 10L/28R closed". */
  title: string;
  /** A second sentence when the notice says more ("For construction work."); null otherwise. */
  detail: string | null;
  /**
   * How much it matters to a passenger, 0 to 100: a closed airport 100, a closed runway 80 (50 when
   * partly), an ILS 60, construction 35 (runway) or 20, a taxiway 25, an unlit obstacle 5, a closure
   * to private flights only 2, anything else 0.
   */
  relevance: number;
}

/** One NOTAM as faa-notams answers it. Times are ISO 8601 UTC. */
export interface Notam {
  /** The FAA's number ("10/123", "A1234/26"). */
  number: string;
  kind: NotamKind;
  title: string;
  detail: string | null;
  relevance: number;
  /** The notice as published, for the app to show under the plain words. */
  raw: string;
  starts_at: string | null;
  /** null when permanent or open ended. */
  ends_at: string | null;
  /** True when the end is an estimate ("EST" in the notice). */
  ends_estimated: boolean;
}

const words = (s: string) => s.replace(/\s+/g, " ").trim();

/**
 * The body of a notice: the ICAO E) field when there is one; else the domestic text without its
 * header ("!SFO 10/123 SFO ") and its trailing validity ("2610301400-2610302200", "PERM", "EST").
 */
export function noticeBody(text: string): string {
  let s = words(text.toUpperCase());
  const e = /(?:^|\s)E\)\s*(.*?)(?:\s[FG]\)|$)/.exec(s);
  if (e) s = e[1];
  s = s.replace(/^!\S+\s+\d{1,2}\/\d{1,4}\s+\S+\s+/, "");
  s = s.replace(/\s+\d{10}(?:-(?:\d{10}(?:EST)?|PERM))?$/, "");
  s = s.replace(/\s+(?:PERM|EST)$/, "");
  return s.replace(/\.$/, "").trim();
}

/** "TWY A, B" or "TWY A AND B": the taxiway names. */
function taxiways(s: string): string[] {
  return s.replace(/\bTWY\b/g, "").split(/,|\bAND\b/).map((t) => t.trim())
    .filter((t) => /^[A-Z]{1,2}\d{0,2}$/.test(t));
}

function list(items: string[]): string {
  if (items.length <= 1) return items.join("");
  return `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;
}

const OTHER: Decoded = { kind: "other", title: "", detail: null, relevance: 0 };

const WORK = /\b(?:WIP|CONST|CONSTRUCTION|WORK IN PROGRESS|MAINT)\b/;

/** The plain English of one notice (see the header). */
export function decodeNotam(text: string): Decoded {
  const b = noticeBody(text);

  // The airport.
  const ad = /^(?:AD AP|AD|AP|AERODROME|AIRPORT) (?:CLSD|CLOSED)\b(.*)$/.exec(b);
  if (ad) {
    const rest = ad[1].trim();
    if (rest === "") {
      return {
        kind: "airport_closed",
        title: "Airport closed",
        detail: null,
        relevance: 100,
      };
    }
    if (/TRANSIENT|NON SKED|\bGA\b|PPR/.test(rest)) {
      return {
        kind: "airport_closed",
        title: "Closed to private and charter flights",
        detail: "Airline flights are not affected.",
        relevance: 2,
      };
    }
    return {
      kind: "airport_closed",
      title: "Airport closed, with exceptions",
      detail: null,
      relevance: 50,
    };
  }

  // A runway.
  const rwy =
    /^(?:RWY|RUNWAY) (\d{1,2}[LRC]?(?:\/\d{1,2}[LRC]?)?) (?:CLSD|CLOSED|NOT AVBL)\b(.*)$/
      .exec(b);
  if (rwy) {
    const rest = rwy[2];
    const partial = /\bEXC\b|\bTO\b|\bBTN\b|\bFIRST\b|\bLAST\b/.test(rest);
    return {
      kind: "runway_closed",
      title: `Runway ${rwy[1]} closed${partial ? " in part" : ""}`,
      detail: WORK.test(rest) ? "For construction work." : null,
      relevance: partial ? 50 : 80,
    };
  }

  // A taxiway (or several).
  const twy = /^(TWY .+?) CLSD\b/.exec(b);
  if (twy) {
    const between =
      /^(TWY [A-Z0-9]{1,4}) BTN (?:TWY )?([A-Z0-9]{1,4}) AND (?:TWY |RWY )?([A-Z0-9/]{1,8})/
        .exec(twy[1]);
    if (between) {
      const name = between[1].slice(4);
      return {
        kind: "taxiway_closed",
        title: `Taxiway ${name} closed in part`,
        detail: `Between ${between[2]} and ${between[3]}.`,
        relevance: 25,
      };
    }
    const names = taxiways(twy[1]);
    if (names.length) {
      return {
        kind: "taxiway_closed",
        title: `${names.length > 1 ? "Taxiways" : "Taxiway"} ${
          list(names)
        } closed`,
        detail: null,
        relevance: 25,
      };
    }
  }

  // An instrument landing system.
  const ils =
    /^(?:NAV )?ILS(?:\/DME)? (?:RWY )?(\d{1,2}[LRC]?)\b(.*?)\b(?:U\/S|OUT OF SERVICE|OTS|UNSERVICEABLE|NOT AVBL|INOP)\b/
      .exec(b);
  if (ils) {
    const part = /\b(?:GP|GS)\b/.test(ils[2])
      ? "ILS glide slope"
      : /\bLOC\b/.test(ils[2])
      ? "ILS localizer"
      : /\bDME\b/.test(ils[2])
      ? "ILS distance equipment"
      : "ILS";
    return {
      kind: "ils_out",
      title: `${part} for runway ${ils[1]} out of service`,
      detail: "Landings in low cloud or fog may be slower.",
      relevance: 60,
    };
  }

  // An obstacle whose light is out.
  if (
    /^OBST\b/.test(b) && /\bLGT\b/.test(b) &&
    /\b(?:U\/S|OUT OF SERVICE|OTS)\b/.test(b)
  ) {
    const what = /\b(TOWER|CRANE|WIND TURBINE|STACK|BLDG|ANTENNA|POLE)\b/.exec(
      b,
    )?.[1];
    const name = what === "BLDG"
      ? "building"
      : what?.toLowerCase() ?? "obstacle";
    const where = /\((\d+(?:\.\d+)?)NM ([NSEW]{1,3}) [A-Z0-9]{3,4}\)/.exec(b);
    const height = /(\d{2,5})FT \((\d{1,5})FT AGL\)/.exec(b);
    const parts = [
      where ? `${where[1]} NM ${where[2]} of the airport` : null,
      height ? `${Number(height[2])} ft tall` : null,
    ].filter(Boolean);
    return {
      kind: "obstacle_light",
      title: `Unlit ${name}`,
      detail: parts.length
        ? `${parts.join(", ").replace(/^./, (c) => c.toUpperCase())}.`
        : null,
      relevance: 5,
    };
  }

  // Construction anywhere on the field.
  if (WORK.test(b) || /^OBST CRANE\b/.test(b)) {
    const rw = /\bRWY (\d{1,2}[LRC]?(?:\/\d{1,2}[LRC]?)?)/.exec(b);
    const tw = /\bTWY ([A-Z]{1,2}\d{0,2})\b/.exec(b);
    const where = rw
      ? `on runway ${rw[1]}`
      : tw
      ? `on taxiway ${tw[1]}`
      : /\bAPRON|RAMP\b/.test(b)
      ? "on the apron"
      : /\bTERMINAL|TERM\b/.test(b)
      ? "by the terminal"
      : "at the airport";
    return {
      kind: "construction",
      title: `Construction ${where}`,
      detail: /^OBST CRANE\b/.test(b) ? "Cranes are up near the field." : null,
      relevance: rw ? 35 : 20,
    };
  }
  return OTHER;
}

/** Most felt first, then the ones in effect earliest. */
export function rankNotams(ns: Notam[]): Notam[] {
  return [...ns].sort((a, b) =>
    b.relevance - a.relevance ||
    (a.starts_at ?? "").localeCompare(b.starts_at ?? "") ||
    a.number.localeCompare(b.number)
  );
}

// ---- The FAA NOTAM API -------------------------------------------------------------------------

export const NOTAM_URL = "https://external-api.faa.gov/notamapi/v1/notams";
export const NOTAM_TIMEOUT_MS = 15_000;
/** At most this many notices go back to the app. */
export const MAX_NOTAMS = 30;
/** Notices starting later than this are left out: a passenger looks at today and tomorrow. */
export const AHEAD_MS = 36 * 3600_000;

export interface NotamCredentials {
  clientId: string;
  clientSecret: string;
  /** The endpoint; NOTAM_URL unless FAA_NOTAM_URL says otherwise. */
  url: string;
}

/** The credentials from the env; undefined when either is missing (the function then answers not configured). */
export function credentialsFromEnv(
  get: (name: string) => string | undefined = (n) => Deno.env.get(n),
): NotamCredentials | undefined {
  const clientId = get("FAA_NOTAM_CLIENT_ID")?.trim();
  const clientSecret = get("FAA_NOTAM_CLIENT_SECRET")?.trim();
  if (!clientId || !clientSecret) return undefined;
  return {
    clientId,
    clientSecret,
    url: get("FAA_NOTAM_URL")?.trim() || NOTAM_URL,
  };
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null =>
  v && typeof v === "object" && !Array.isArray(v) ? v as Obj : null;
const str = (v: unknown): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : null;

/** "2026-10-30T22:00:00.000Z" as ISO, "PERM" as null; the second value says "EST". */
function end(v: unknown): { at: string | null; estimated: boolean } {
  const s = str(v);
  if (!s || /^PERM/i.test(s)) return { at: null, estimated: false };
  const estimated = /EST$/i.test(s);
  const t = Date.parse(s.replace(/EST$/i, ""));
  return {
    at: Number.isFinite(t) ? new Date(t).toISOString() : null,
    estimated,
  };
}

function start(v: unknown): string | null {
  const s = str(v);
  const t = s ? Date.parse(s) : NaN;
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

/**
 * The passenger-relevant notices of a NOTAM API answer, decoded and ranked, in effect at `now` or
 * starting within AHEAD_MS, at most MAX_NOTAMS. Cancellations (type C) are left out. Throws when the
 * answer has no item list.
 */
export function parseNotamApi(body: unknown, now: Date): Notam[] {
  const items = obj(body)?.items;
  if (!Array.isArray(items)) throw new Error("NOTAM answer has no items");
  const t = now.getTime();
  const out: Notam[] = [];
  for (const item of items) {
    const core = obj(obj(obj(item)?.properties)?.coreNOTAMData);
    const n = obj(core?.notam);
    if (!n || str(n.type) === "C") continue;
    const local = (Array.isArray(core?.notamTranslation)
      ? core.notamTranslation as unknown[]
      : [])
      .map(obj).find((x) =>
        x && str(x.type) === "LOCAL_FORMAT"
      );
    const raw = str(local?.simpleText) ?? str(n.text);
    if (!raw) continue;
    const d = decodeNotam(str(n.text) ?? raw);
    if (d.kind === "other") continue;
    const from = start(n.effectiveStart);
    const until = end(n.effectiveEnd);
    if (until.at && Date.parse(until.at) <= t) continue;
    if (from && Date.parse(from) > t + AHEAD_MS) continue;
    out.push({
      number: str(n.number) ?? str(n.id) ?? "",
      kind: d.kind,
      title: d.title,
      detail: d.detail,
      relevance: d.relevance,
      raw,
      starts_at: from,
      ends_at: until.at,
      ends_estimated: until.estimated,
    });
  }
  return rankNotams(out).slice(0, MAX_NOTAMS);
}

/** Fetches the notices of `icao`. Throws on a network failure, a refused key or an unreadable answer. */
export async function fetchNotams(
  creds: NotamCredentials,
  icao: string,
  fetchFn: typeof fetch,
  now: Date,
): Promise<Notam[]> {
  const url = new URL(creds.url);
  url.searchParams.set("icaoLocation", icao);
  url.searchParams.set("pageSize", "1000");
  const res = await fetchFn(url, {
    headers: {
      accept: "application/json",
      client_id: creds.clientId,
      client_secret: creds.clientSecret,
    },
    signal: AbortSignal.timeout(NOTAM_TIMEOUT_MS),
  });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`NOTAM API answered ${res.status}`);
  }
  return parseNotamApi(await res.json(), now);
}

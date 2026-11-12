/** One airline of the shared reference list (airlines.json): the fields the parser reads. */
export type AirlineRow = { icao: string; iata: string; name: string };

/** What the forgiving forms need of the airline list: is this a code, and which code does this name give. */
export type AirlineDirectory = {
  /** True when `code` (IATA or ICAO, any case) is an airline's. */
  hasCode(code: string): boolean;
  /** The code flight numbers use (IATA, else ICAO) of the airline named by `phrase`, whole or without its tail. */
  named(phrase: string): string | null;
};

export type FlightNumber = { airline: string; number: string };

/** Lower case, accents dropped, anything but letters and digits a space (SearchText.fold). */
export function fold(s: string): string {
  return s
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/** Generic tails an airline is often named without (SearchSuggester.airlineTails). */
const TAILS = [" air lines", " airlines", " airline", " airways"];

/** Names from the rows; `hasCode` is the shared directory's lookup (src/ui/airlines.ts) when given, else the rows' own codes. */
export function buildAirlineDirectory(rows: readonly AirlineRow[], knows?: (code: string) => boolean): AirlineDirectory {
  const codes = new Set<string>();
  const exact = new Map<string, string>();
  const short = new Map<string, string>();
  for (const r of rows) {
    if (r.iata) codes.add(r.iata.toUpperCase());
    if (r.icao) codes.add(r.icao.toUpperCase());
    const code = (r.iata || r.icao).toUpperCase();
    const name = fold(r.name);
    if (!name) continue;
    if (!exact.has(name)) exact.set(name, code);
    const tail = TAILS.find((t) => name.endsWith(t));
    if (tail) {
      const s = name.slice(0, -tail.length);
      if (s && !short.has(s)) short.set(s, code);
    }
  }
  return {
    hasCode: (c) => (knows ? knows(c) : codes.has(c.toUpperCase())),
    named: (p) => {
      const q = fold(p);
      return q ? (exact.get(q) ?? short.get(q) ?? null) : null;
    },
  };
}

/** Words that stand for "to", "from" or nothing: a two-letter word among them is no airline code. */
const WORDS = new Set([
  "to", "vers", "a", "pour", "for", "towards", "from", "de", "depuis", "du",
  "flight", "flights", "vol", "vols", "the", "le", "la", "les", "on", "at", "in", "et", "and", "en", "au", "aux", "des", "un", "une",
]);

const GLUED = /^([a-z]{2,3}|[a-z][0-9]|[0-9][a-z])([0-9]{1,4})$/;
const CODE = /^([a-z]{2,3}|[a-z][0-9]|[0-9][a-z])$/;
const NUMBER = /^[0-9]{1,4}$/;

/**
 * The first flight number in `text`, however it is typed: "af84", "AF 84", "u2 1234", and with a list of
 * airlines the forgiving forms "84 af", "air france 84", "84 air france". Port of FlightQuery.parse plus
 * SearchIntent.ident / looseIdent. Without a list a code only has to look like one (two or three letters,
 * or a letter and a digit); with it, a code must be an airline's, or two characters that are no small word
 * ("la" reads as LATAM only through the list). A bare number is no flight.
 */
export function parseFlightNumber(text: string, airlines?: AirlineDirectory): FlightNumber | null {
  const w = fold(text).split(" ").filter(Boolean);
  if (w.length === 0) return null;
  const airlineCode = (c: string): boolean => {
    if (!airlines) return true;
    return airlines.hasCode(c) || (c.length === 2 && !WORDS.has(c));
  };

  for (let i = 0; i < w.length; i++) {
    const m = GLUED.exec(w[i]);
    if (m && airlineCode(m[1])) return out(m[1], m[2]);
    if (i + 1 < w.length && CODE.test(w[i]) && NUMBER.test(w[i + 1]) && airlineCode(w[i])) return out(w[i], w[i + 1]);
  }
  return airlines ? looseNumber(w, airlines) : null;
}

/** "84 af", "air france 84", "84 air france": a number beside a known airline's code (number first) or name. */
function looseNumber(w: string[], airlines: AirlineDirectory): FlightNumber | null {
  const number = (k: number) => k >= 0 && k < w.length && NUMBER.test(w[k]);
  const named = (k: number, n: number): string | null => (k >= 0 && k + n <= w.length ? airlines.named(w.slice(k, k + n).join(" ")) : null);
  for (let i = 0; i < w.length; i++) {
    if (!number(i)) continue;
    const next = w[i + 1];
    if (next && next.length === 2 && /\p{L}/u.test(next) && !WORDS.has(next) && airlines.hasCode(next)) return out(next, w[i]);
    for (let n = Math.min(4, i); n >= 1; n--) {
      const c = named(i - n, n);
      if (c) return out(c, w[i]);
    }
    for (let n = Math.min(4, w.length - i - 1); n >= 1; n--) {
      const c = named(i + 1, n);
      if (c) return out(c, w[i]);
    }
  }
  return null;
}

function out(code: string, number: string): FlightNumber {
  return { airline: code.toUpperCase(), number };
}

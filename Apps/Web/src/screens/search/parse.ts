import { fold, type AirlineDirectory } from "@/ui/airlines";

export type FlightNumber = { airline: string; number: string };

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
    if (!airlines) return !WORDS.has(c);
    return airlines(c) !== null || (c.length === 2 && !WORDS.has(c));
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
    if (next && next.length === 2 && /\p{L}/u.test(next) && !WORDS.has(next) && airlines(next) !== null) return out(next, w[i]);
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

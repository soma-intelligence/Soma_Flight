import type { Friend, FriendFlight } from "@/data/friends";
import { friendName } from "@/data/friends";
import type { Flight } from "@/data/types";
import { bestIn, bestOut, destinationCode, ident, originCode } from "@/ui/format";
import type { AirportInfo } from "@/ui/airports";

export const EMPTY_TITLE = "Fly apart, stay close";
export const EMPTY_TEXT = "See each other's flights, only with the people you pick.";

const airborne = (f: Flight) => f.status === "departed" || f.status === "en_route";

/** A friend's next flight: the one in the air, else the first not yet landed (FriendsStore.upcomingFlight). */
export function upcomingFlight(flights: FriendFlight[], friendId: string): Flight | null {
  const mine = flights.filter((x) => x.friendId === friendId).map((x) => x.flight);
  return mine.find(airborne) ?? mine.find((f) => f.status !== "landed" && f.status !== "arrived") ?? null;
}

export type SectionId = "in-the-air" | "upcoming" | "none";
export const SECTION_TITLE: Record<SectionId, string> = {
  "in-the-air": "In the Air",
  upcoming: "Upcoming",
  none: "No Upcoming Flights",
};

const byName = (a: Friend, b: Friend) =>
  friendName(a).localeCompare(friendName(b), undefined, { sensitivity: "base" }) || (a.id < b.id ? -1 : 1);

/**
 * The tab's list (FriendsStore.sections): friends in the air (landing soonest first), then those with a
 * flight coming up (leaving soonest first), then everyone else by name. Empty sections are left out.
 */
export function sections(friends: Friend[], flights: FriendFlight[]): { id: SectionId; friends: Friend[] }[] {
  const FAR = Number.POSITIVE_INFINITY;
  const air: [Friend, number][] = [];
  const soon: [Friend, number][] = [];
  const rest: Friend[] = [];
  for (const friend of friends) {
    const f = upcomingFlight(flights, friend.id);
    if (!f) rest.push(friend);
    else if (airborne(f)) air.push([friend, bestIn(f)?.getTime() ?? FAR]);
    else soon.push([friend, bestOut(f)?.getTime() ?? FAR]);
  }
  const byTime = (l: [Friend, number][]) => l.sort((a, b) => (a[1] === b[1] ? byName(a[0], b[0]) : a[1] - b[1])).map((x) => x[0]);
  const all: { id: SectionId; friends: Friend[] }[] = [
    { id: "in-the-air", friends: byTime(air) },
    { id: "upcoming", friends: byTime(soon) },
    { id: "none", friends: rest.sort(byName) },
  ];
  return all.filter((s) => s.friends.length > 0);
}

/** A wait in a few characters: "40 min", "1h 40m" (under 3 hours), "3h", "1 day", "4 days". */
export function waitSpan(minutes: number): string {
  const m = Math.max(0, minutes);
  if (m < 60) return `${m} min`;
  if (m < 24 * 60) {
    const h = Math.floor(m / 60);
    const rest = m % 60;
    return h < 3 && rest > 0 ? `${h}h ${rest}m` : `${h}h`;
  }
  const d = Math.floor(m / (24 * 60));
  return d === 1 ? "1 day" : `${d} days`;
}

export type Tone = "on-time" | "very-late" | "diverted" | "secondary";

/** The short status after the route on a friend's row, with its tone: "departs in 3h", "in the air · lands in 1h 20m". */
export function when(f: Flight, now: Date): { text: string; tone: Tone } {
  switch (f.status) {
    case "canceled":
      return { text: "canceled", tone: "very-late" };
    case "diverted":
      return { text: "diverted", tone: "diverted" };
    case "landed":
    case "arrived":
      return { text: "landed", tone: "secondary" };
    case "departed":
    case "en_route": {
      const end = bestIn(f);
      const left = end ? Math.trunc((end.getTime() - now.getTime()) / 60_000) : 0;
      return { text: left > 0 ? `in the air · lands in ${waitSpan(left)}` : "in the air", tone: "on-time" };
    }
    default: {
      const out = bestOut(f);
      if (!out) return { text: "scheduled", tone: "on-time" };
      const m = Math.trunc((out.getTime() - now.getTime()) / 60_000);
      return { text: m <= 0 ? "departing now" : `departs in ${waitSpan(m)}`, tone: "on-time" };
    }
  }
}

/** "AF 84 · Paris → San Francisco": the flight and its cities (codes when an airport is unknown). */
export function route(f: Flight, lookup: (code: string) => AirportInfo | null): string {
  const from = lookup(f.originIcao)?.city ?? originCode(f);
  const to = lookup(f.destinationIcao)?.city ?? destinationCode(f);
  return `${ident(f.ident)} · ${from} → ${to}`;
}

/** "Friends since October 2026". */
export function since(d: Date): string {
  return `Friends since ${new Intl.DateTimeFormat("en-US", { month: "long", year: "numeric" }).format(d)}`;
}

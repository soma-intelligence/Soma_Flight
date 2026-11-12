import { describe, expect, it } from "vitest";
import type { Friend, FriendFlight } from "@/data/friends";
import { ua990 } from "@/test/flight";
import { sections, since, upcomingFlight, waitSpan, when } from "./facts";

const NOW = new Date("2026-10-30T12:00:00Z");
const friend = (id: string, name: string): Friend => ({
  id,
  displayName: name,
  emoji: null,
  since: new Date("2026-10-02T00:00:00Z"),
  shareFlights: true,
  sharePassport: false,
  alerts: false,
  sharesFlights: true,
  sharesPassport: false,
});
const ff = (friendId: string, over: Parameters<typeof ua990>[0]): FriendFlight => ({ friendId, flight: ua990(over) });

describe("friends facts", () => {
  it("spans a wait in a few characters", () => {
    expect(waitSpan(40)).toBe("40 min");
    expect(waitSpan(100)).toBe("1h 40m");
    expect(waitSpan(180)).toBe("3h");
    expect(waitSpan(48 * 60)).toBe("2 days");
    expect(waitSpan(24 * 60)).toBe("1 day");
  });

  it("words a flight's status", () => {
    expect(when(ua990({ scheduledOut: new Date(NOW.getTime() + 3 * 3600_000) }), NOW).text).toBe("departs in 3h");
    expect(when(ua990({ status: "canceled" }), NOW)).toEqual({ text: "canceled", tone: "very-late" });
    expect(when(ua990({ status: "en_route", scheduledIn: new Date(NOW.getTime() + 80 * 60_000) }), NOW).text).toBe(
      "in the air · lands in 1h 20m",
    );
  });

  it("puts friends in the air first, then upcoming by time, then the rest by name", () => {
    const friends = [friend("a", "Zed"), friend("b", "Bo"), friend("c", "Cy"), friend("d", "Al")];
    const flights = [
      ff("a", { id: "f1", status: "scheduled", scheduledOut: new Date(NOW.getTime() + 5 * 3600_000) }),
      ff("b", { id: "f2", status: "scheduled", scheduledOut: new Date(NOW.getTime() + 2 * 3600_000) }),
      ff("c", { id: "f3", status: "en_route", scheduledIn: new Date(NOW.getTime() + 3600_000) }),
    ];
    const s = sections(friends, flights);
    expect(s.map((x) => x.id)).toEqual(["in-the-air", "upcoming", "none"]);
    expect(s[0]!.friends.map((f) => f.id)).toEqual(["c"]);
    expect(s[1]!.friends.map((f) => f.id)).toEqual(["b", "a"]);
    expect(s[2]!.friends.map((f) => f.id)).toEqual(["d"]);
  });

  it("a landed flight is not upcoming, and a friend's next flight is the one in the air first", () => {
    const flights = [ff("a", { id: "f1", status: "landed" }), ff("a", { id: "f2", status: "scheduled" })];
    expect(upcomingFlight(flights, "a")?.id).toBe("f2");
    expect(upcomingFlight([ff("a", { status: "arrived" })], "a")).toBeNull();
  });

  it("words the friendship's start", () => {
    expect(since(new Date("2026-10-15T12:00:00Z"))).toBe("Friends since October 2026");
  });
});

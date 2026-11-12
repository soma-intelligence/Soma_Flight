// Development only: import this module behind `if (import.meta.env.DEV)`.
import type { PastFlight } from "@/data/passport";

type Seed = [
  id: number,
  iso: string,
  ident: string,
  from: string,
  to: string,
  tz: string,
  airline: string | null,
  type: string | null,
  km: number,
  block: number,
  delay: number,
  fromCountry: string,
  toCountry: string,
  status?: PastFlight["status"],
];

const SEEDS: Seed[] = [
  [1, "2025-02-08T19:00:00Z", "AF83", "LFPG", "KSFO", "Europe/Paris", "AFR", "B77W", 8950, 640, 20, "FR", "US"],
  [2, "2025-03-21T20:00:00Z", "UA1", "KSFO", "KJFK", "America/Los_Angeles", "UAL", "B739", 4150, 330, 5, "US", "US"],
  [3, "2025-05-30T11:00:00Z", "BA286", "EGLL", "KSFO", "Europe/London", "BAW", "B772", 8620, 625, 35, "GB", "US"],
  [4, "2025-08-14T03:00:00Z", "NH105", "RJTT", "KLAX", "Asia/Tokyo", "ANA", "B789", 8815, 600, 0, "JP", "US"],
  [5, "2025-11-02T10:00:00Z", "LH455", "EDDF", "EGLL", "Europe/Berlin", "DLH", "A320", 650, 95, 12, "DE", "GB"],
  [6, "2026-01-17T17:00:00Z", "DL401", "KJFK", "KSFO", "America/New_York", "DAL", "A321", 4150, 395, 48, "US", "US"],
  [7, "2026-03-09T08:00:00Z", "IB6250", "LEMD", "KJFK", "Europe/Madrid", "IBE", "A332", 5760, 505, 10, "ES", "US"],
  [8, "2026-06-25T19:00:00Z", "UA85", "KSFO", "EGLL", "America/Los_Angeles", "UAL", "B789", 8620, 635, 22, "US", "GB"],
  [9, "2026-09-12T12:00:00Z", "AF66", "KJFK", "LFPG", "America/New_York", "AFR", "A388", 5840, 450, 0, "US", "FR"],
  [10, "2026-10-04T10:00:00Z", "UA990", "KSFO", "KLAX", "America/Los_Angeles", "UAL", "B739", 545, 85, 0, "US", "US", "canceled"],
];

function make(s: Seed): PastFlight {
  const [n, iso, ident, from, to, tz, airline, type, km, block, delay, fc, tc, status] = s;
  return {
    id: `cccccccc-0000-4000-8000-${String(n).padStart(12, "0")}`,
    date: new Date(iso),
    ident,
    originIcao: from,
    destinationIcao: to,
    airline,
    aircraftType: type,
    registration: null,
    seat: null,
    distanceKm: km,
    blockMinutes: block,
    delayMinutes: delay,
    status: status ?? "completed",
    originTz: tz,
    seatClass: null,
    reason: null,
    bookingCode: null,
    notes: null,
    originCountry: fc,
    destinationCountry: tc,
    airMinutes: block - 25,
    seatPosition: null,
    source: n % 2 ? "archive" : "manual",
    arrivalDelayMinutes: delay,
    departureDelayMinutes: null,
  };
}

let list: PastFlight[] = SEEDS.map(make);

/** The local past flights, newest first (a copy). */
export function fakePastFlights(): PastFlight[] {
  return [...list].sort((a, b) => b.date.getTime() - a.date.getTime());
}

export function addFakePast(f: PastFlight): void {
  list = [f, ...list];
}

export function deleteFakePast(id: string): boolean {
  const n = list.length;
  list = list.filter((f) => f.id !== id);
  return list.length < n;
}

export function resetFakePast(): void {
  list = SEEDS.map(make);
}

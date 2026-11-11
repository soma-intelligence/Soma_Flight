import { describe, expect, it } from "vitest";
import { decodeFlight } from "./decode";

const base = {
  id: "11111111-1111-4111-8111-111111111111",
  provider_id: "UAL123-1",
  ident: "UA123",
  origin_icao: "KSFO",
  destination_icao: "KJFK",
  status: "scheduled",
  updated_at: "2026-11-11T10:00:00.000Z",
};

describe("decodeFlight", () => {
  it("reads dates with and without milliseconds", () => {
    const f = decodeFlight({
      ...base,
      scheduled_out: "2026-11-11T12:30:00.123Z",
      scheduled_in: "2026-11-11T20:30:00Z",
    });
    expect(f.scheduledOut?.toISOString()).toBe("2026-11-11T12:30:00.123Z");
    expect(f.scheduledIn?.toISOString()).toBe("2026-11-11T20:30:00.000Z");
    expect(f.providerId).toBe("UAL123-1");
    expect(f.originIcao).toBe("KSFO");
    expect(f.updatedAt).toBeInstanceOf(Date);
  });

  it("keeps null scheduled_out as null", () => {
    const f = decodeFlight({ ...base, scheduled_out: null });
    expect(f.scheduledOut).toBeNull();
    expect(decodeFlight(base).scheduledOut).toBeNull();
  });

  it("builds the position from flat columns", () => {
    const f = decodeFlight({
      ...base,
      status: "en_route",
      position_lat: 40.1,
      position_lon: -100.2,
      position_heading: 85,
      position_altitude_ft: 36000,
      position_ground_speed_kt: 480,
      position_at: "2026-11-11T11:59:00Z",
    });
    expect(f.status).toBe("en_route");
    expect(f.position).toMatchObject({ lat: 40.1, lon: -100.2, heading: 85, altitudeFt: 36000, groundSpeedKt: 480 });
    expect(decodeFlight(base).position).toBeNull();
  });

  it("maps an unknown status to unknown and rejects a row without id", () => {
    expect(decodeFlight({ ...base, status: "weird" }).status).toBe("unknown");
    expect(() => decodeFlight({ ...base, id: undefined })).toThrow();
    expect(() => decodeFlight("nope")).toThrow();
  });
});

import { beforeEach, describe, expect, it, vi } from "vitest";

const order = vi.fn();
const select = vi.fn(() => ({ order }));
const from = vi.fn(() => ({ select }));
const on = vi.fn();
const subscribe = vi.fn();
const channelObj = { on, subscribe };
on.mockReturnValue(channelObj);
subscribe.mockReturnValue(channelObj);
const channel = vi.fn(() => channelObj);
const removeChannel = vi.fn();

vi.mock("./client", () => ({ getSupabase: () => ({ from, channel, removeChannel }) }));

import { fakesEnabled, fetchMyFlights } from "./flights";
import { subscribeFlights } from "./realtime";

const row = {
  id: "11111111-1111-4111-8111-111111111111",
  provider_id: "p",
  ident: "UA1",
  origin_icao: "KSFO",
  destination_icao: "KJFK",
  status: "scheduled",
  updated_at: "2026-11-11T10:00:00Z",
};

beforeEach(() => vi.clearAllMocks());

describe("fetchMyFlights", () => {
  it("builds the user_flights query", async () => {
    order.mockResolvedValueOnce({
      data: [
        { created_at: "2026-11-10T09:00:00.000Z", flights: row },
        { created_at: "2026-11-10T10:00:00.000Z", flights: null },
        { created_at: "2026-11-10T11:00:00.000Z", flights: { id: "bad" } },
      ],
      error: null,
    });
    const out = await fetchMyFlights();
    expect(from).toHaveBeenCalledWith("user_flights");
    expect(select).toHaveBeenCalledWith("created_at, flights(*)");
    expect(order).toHaveBeenCalledWith("created_at");
    expect(out).toHaveLength(1);
    expect(out[0].flight.ident).toBe("UA1");
    expect(out[0].createdAt).toBeInstanceOf(Date);
  });

  it("throws ApiError on a postgrest error", async () => {
    order.mockResolvedValueOnce({ data: null, error: { code: "PGRST301", message: "jwt" } });
    await expect(fetchMyFlights()).rejects.toMatchObject({ code: "unauthorized" });
  });
});

describe("subscribeFlights", () => {
  it("opens one channel filtered by id=in.(...) and removes it on unsubscribe", () => {
    const off = subscribeFlights(["a", "b"], () => {});
    expect(channel).toHaveBeenCalledTimes(1);
    expect(on).toHaveBeenCalledWith(
      "postgres_changes",
      { event: "UPDATE", schema: "public", table: "flights", filter: "id=in.(a,b)" },
      expect.any(Function),
    );
    expect(removeChannel).not.toHaveBeenCalled();
    off();
    expect(removeChannel).toHaveBeenCalledWith(channelObj);
  });

  it("delivers decoded rows and opens nothing for no ids", () => {
    const onRow = vi.fn();
    subscribeFlights(["a"], onRow);
    const handler = on.mock.calls[0][2] as (p: { new: unknown }) => void;
    handler({ new: row });
    expect(onRow).toHaveBeenCalledTimes(1);
    handler({ new: { id: "bad" } });
    expect(onRow).toHaveBeenCalledTimes(1);
    channel.mockClear();
    subscribeFlights([], onRow)();
    expect(channel).not.toHaveBeenCalled();
  });
});

describe("fakesEnabled", () => {
  it("is true only in development with ?fakes=1", () => {
    expect(fakesEnabled(true, "?fakes=1")).toBe(true);
    expect(fakesEnabled(true, "")).toBe(false);
    expect(fakesEnabled(false, "?fakes=1")).toBe(false);
  });
});

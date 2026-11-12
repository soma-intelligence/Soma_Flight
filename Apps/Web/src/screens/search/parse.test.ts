import { describe, expect, it } from "vitest";
import { parseAirlines } from "@/ui/airlines";
import { parseFlightNumber } from "./parse";

const rows = [
  { icao: "AFR", iata: "AF", name: "Air France" },
  { icao: "DAL", iata: "DL", name: "Delta Air Lines" },
  { icao: "UAL", iata: "UA", name: "United Airlines" },
  { icao: "LAN", iata: "LA", name: "LATAM Airlines" },
  { icao: "EZY", iata: "U2", name: "easyJet" },
  { icao: "BER", iata: "", name: "Berlin Air" },
  { icao: "AWQ", iata: "9W", name: "Jet Airways" },
  { icao: "DLH", iata: "DL", name: "Delta Air Lines" },
  { icao: "OAL", iata: "OA", name: "Olympic Airways" },
];
const dir = parseAirlines(rows);

describe("parseFlightNumber, FlightQuery.parse rule", () => {
  it.each([
    ["AF84", "AF", "84"],
    ["af84", "AF", "84"],
    ["AF 84", "AF", "84"],
    ["  ua 990 ", "UA", "990"],
    ["U2 1234", "U2", "1234"],
    ["u21234", "U2", "1234"],
    ["B6717", "B6", "717"],
    ["6E 204", "6E", "204"],
    ["EZY 8001", "EZY", "8001"],
  ])("%s", (text, airline, number) => {
    expect(parseFlightNumber(text)).toEqual({ airline, number });
    expect(parseFlightNumber(text, dir)).toEqual({ airline, number });
  });

  it.each(["", "   ", "84", "AF", "AF 12345", "A 84", "paris", "cdg lax"])("reads no flight in %j", (text) => {
    expect(parseFlightNumber(text)).toBeNull();
  });
});

describe("parseFlightNumber, forgiving forms", () => {
  it.each(["air france 84", "Air France 84", "84 af", "84 air france", "AF84 "])("%j is AF84", (text) => {
    expect(parseFlightNumber(text, dir)).toEqual({ airline: "AF", number: "84" });
  });

  it("reads the airline by its name without a generic tail", () => {
    expect(parseFlightNumber("delta 220", dir)).toEqual({ airline: "DL", number: "220" });
    expect(parseFlightNumber("220 united", dir)).toEqual({ airline: "UA", number: "220" });
  });

  it("a name the list does not know is no flight, and a bare number is no flight", () => {
    expect(parseFlightNumber("84", dir)).toBeNull();
    expect(parseFlightNumber("zebra air 84", dir)).toBeNull();
  });

  it("Swift cases: DAL 220, 9W 123, DL2204, AF 12 12", () => {
    expect(parseFlightNumber("DAL 220", dir)).toEqual({ airline: "DAL", number: "220" });
    expect(parseFlightNumber("9W 123", dir)).toEqual({ airline: "9W", number: "123" });
    expect(parseFlightNumber("DL2204", dir)).toEqual({ airline: "DL", number: "2204" });
    // The first number after the code is the flight's; the rest is left over (no date reading here).
    expect(parseFlightNumber("AF 12 12", dir)).toEqual({ airline: "AF", number: "12" });
  });

  it("drops apostrophes before reading", () => {
    expect(parseFlightNumber("air franc'e 84", dir)).toEqual({ airline: "AF", number: "84" });
    expect(parseFlightNumber("AF’84", dir)).toEqual({ airline: "AF", number: "84" });
  });

  it("small words are no code even without a directory", () => {
    expect(parseFlightNumber("to 12")).toBeNull();
    expect(parseFlightNumber("vol 12")).toBeNull();
    expect(parseFlightNumber("la 12")).toBeNull();
  });

  it("without a directory the name forms are not read", () => {
    expect(parseFlightNumber("air france 84")).toBeNull();
  });

  it("an airline without an IATA code is written with its ICAO code", () => {
    expect(parseFlightNumber("berlin air 7", dir)).toEqual({ airline: "BER", number: "7" });
  });

  it("a code that is a small word yields to the number-first form only when it is an airline", () => {
    expect(parseFlightNumber("la 800", dir)).toEqual({ airline: "LA", number: "800" });
    expect(parseFlightNumber("vol de 12", dir)).toBeNull();
  });

  it("finds the number among other words and takes the first", () => {
    expect(parseFlightNumber("flight af 84 tomorrow", dir)).toEqual({ airline: "AF", number: "84" });
    expect(parseFlightNumber("ua 990 af 84", dir)).toEqual({ airline: "UA", number: "990" });
  });
});

import { describe, expect, it } from "vitest";
import { parseAirportInfo } from "./airports";

describe("parseAirportInfo", () => {
  const dir = parseAirportInfo(
    [
      "SPJC\tLIM\tJorge Chávez International Airport\tLima\tPE\t-12.0219\t-77.1143\tAmerica/Lima\tSPIM",
      "LFPG\tCDG\tParis Charles de Gaulle Airport\tParis\tFR\t49.0097\t2.5479\tEurope/Paris",
    ].join("\n"),
  );

  it("finds an airport by ICAO, IATA and its former code", () => {
    expect(dir("SPJC")?.city).toBe("Lima");
    expect(dir("lim")?.icao).toBe("SPJC");
    expect(dir("SPIM")?.icao).toBe("SPJC");
    expect(dir("LFPG")?.tz).toBe("Europe/Paris");
    expect(dir("XXXX")).toBeNull();
  });
});

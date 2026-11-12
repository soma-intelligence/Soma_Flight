import { describe, expect, it } from "vitest";
import { ua990 } from "@/test/flight";
import { airlineOf, parseAirlines } from "./airlines";
import { airlineCode } from "./format";

const json = [
  { icao: "UAL", iata: "UA", name: "United Airlines" },
  { icao: "AFR", iata: "AF", name: "Air France" },
  { icao: "EJM", iata: "", name: "Executive Jet Management" },
];

describe("airlines (ReferenceData.airline)", () => {
  const dir = parseAirlines(json);

  it("finds an airline by ICAO or IATA code, any case", () => {
    expect(dir("UAL")?.name).toBe("United Airlines");
    expect(dir("ua")?.icao).toBe("UAL");
    expect(dir("EJM")?.iata).toBeNull();
    expect(dir("ZZZ")).toBeNull();
    expect(dir("")).toBeNull();
  });

  it("a flight's airline: its operator, else its number's designator", () => {
    expect(airlineOf(ua990(), dir)?.name).toBe("United Airlines");
    expect(airlineOf(ua990({ operator: null, ident: "AF84" }), dir)?.name).toBe("Air France");
    expect(airlineOf(ua990({ operator: "XXX", ident: "QQ1" }), dir)).toBeNull();
  });

  it("the mark's code: the airline's IATA, else the operator, else the designator", () => {
    expect(airlineCode(ua990(), dir("UAL"))).toBe("UA");
    expect(airlineCode(ua990({ operator: "EJM", ident: "EJM444" }), dir("EJM"))).toBe("EJM");
    expect(airlineCode(ua990({ operator: null, ident: "B6717" }), null)).toBe("B6");
    expect(airlineCode(ua990({ operator: "XYZ" }), null)).toBe("XYZ");
  });
});

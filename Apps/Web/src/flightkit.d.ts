// The FlightKit reference tables the web app imports through the `@flightkit` alias (vite.config.ts).
// A pattern, not the exact path, so an exact declaration elsewhere takes precedence instead of clashing.

/** The rows of a JSON reference table (airlines.json): every field is checked where it is read. */
declare module "@flightkit/Reference/*.json" {
  const rows: readonly { icao?: unknown; iata?: unknown; name?: unknown }[];
  export default rows;
}

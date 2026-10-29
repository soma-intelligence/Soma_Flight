/* tslint:disable */
/* eslint-disable */

/**
 * `as_of` is unix seconds (a JS BigInt); ages are measured up to it.
 */
export function computeAircraftStats(flights_json: string, year: number | null | undefined, types_json: string, facts_json: string, as_of: bigint): string;

export function computePassport(flights_json: string, year?: number | null): string;

export function computePassportDetail(flights_json: string, year: number | null | undefined, countries_json: string): string;

export function computeStats(rows_json: string): string;

/**
 * Haversine distance. Throws a JS `Error` on malformed input.
 */
export function distanceKm(a_json: string, b_json: string): number;

export function flightCategory(ceiling_ft: number | null | undefined, visibility_sm: number): string;

export function greatCircle(a_json: string, b_json: string, segments: number): string;

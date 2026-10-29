/* tslint:disable */
/* eslint-disable */

export function computePassport(flights_json: string, year?: number | null): string;

export function computePassportDetail(flights_json: string, year: number | null | undefined, countries_json: string): string;

export function computeStats(rows_json: string): string;

/**
 * Haversine distance. Throws a JS `Error` on malformed input.
 */
export function distanceKm(a_json: string, b_json: string): number;

export function flightCategory(ceiling_ft: number | null | undefined, visibility_sm: number): string;

export function greatCircle(a_json: string, b_json: string, segments: number): string;

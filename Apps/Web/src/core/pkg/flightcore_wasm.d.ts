/* tslint:disable */
/* eslint-disable */

/**
 * `as_of` is unix seconds (a JS BigInt); ages are measured up to it.
 */
export function computeAircraftStats(flights_json: string, year: number | null | undefined, types_json: string, facts_json: string, as_of: bigint): string;

export function computePassport(flights_json: string, year?: number | null): string;

export function computePassportDetail(flights_json: string, year: number | null | undefined, countries_json: string): string;

export function computeStats(rows_json: string): string;

export function describeWeather(wx: string): string;

/**
 * Haversine distance. Throws a JS `Error` on malformed input.
 */
export function distanceKm(a_json: string, b_json: string): number;

export function flightCategory(ceiling_ft: number | null | undefined, visibility_sm: number): string;

export function greatCircle(a_json: string, b_json: string, segments: number): string;

/**
 * Likely departure delay (`DelayInput` JSON, camelCase): a `DelayPrediction`, or `null` when the
 * signals are weak.
 */
export function predictDelay(input_json: string): string;

/**
 * Likely departure gate from `GateDay` and `GateCount` JSON arrays (camelCase): a `GatePrediction`,
 * or `null` without a clear majority.
 */
export function predictGate(days_json: string, airline_json: string, airline_code?: string | null): string;

export function presentWeather(report: string): string;

/**
 * Weather impact of one observation or forecast period (`Conditions` JSON, camelCase).
 */
export function weatherImpact(conditions_json: string): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly computeAircraftStats: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: bigint) => [number, number];
    readonly computePassport: (a: number, b: number, c: number) => [number, number];
    readonly computePassportDetail: (a: number, b: number, c: number, d: number, e: number) => [number, number];
    readonly computeStats: (a: number, b: number) => [number, number];
    readonly describeWeather: (a: number, b: number) => [number, number];
    readonly distanceKm: (a: number, b: number, c: number, d: number) => [number, number, number];
    readonly flightCategory: (a: number, b: number) => [number, number];
    readonly greatCircle: (a: number, b: number, c: number, d: number, e: number) => [number, number];
    readonly predictDelay: (a: number, b: number) => [number, number];
    readonly predictGate: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number];
    readonly presentWeather: (a: number, b: number) => [number, number];
    readonly weatherImpact: (a: number, b: number) => [number, number];
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;

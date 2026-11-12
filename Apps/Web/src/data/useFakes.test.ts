// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { FAKES_KEY, useFakes } from "./flights";

afterEach(() => {
  sessionStorage.clear();
  window.history.replaceState(null, "", "/");
});

describe("useFakes (development)", () => {
  it("is off without ?fakes=1", () => {
    expect(useFakes()).toBe(false);
  });

  it("turns on with ?fakes=1 and stays on in the tab after the query is gone", () => {
    window.history.replaceState(null, "", "/?fakes=1");
    expect(useFakes()).toBe(true);
    expect(sessionStorage.getItem(FAKES_KEY)).toBe("1");
    window.history.replaceState(null, "", "/friends");
    expect(useFakes()).toBe(true);
  });
});

import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const root = path.resolve(import.meta.dirname, "../../../..");
const swift = readFileSync(path.join(root, "Packages/FlightKit/Sources/FlightKit/UI/Theme.swift"), "utf8");
const css = readFileSync(path.join(import.meta.dirname, "theme.css"), "utf8");

const kebab = (s: string) => s.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
const colors = [
  ...swift.matchAll(/static let (\w+)\s*=\s*Color\(light:\s*0x([0-9A-Fa-f]{6}),\s*dark:\s*0x([0-9A-Fa-f]{6})\)/g),
].map((m) => ({ name: m[1], light: m[2].toLowerCase(), dark: m[3].toLowerCase() }));

/** Body of the first block whose selector line starts with `selector`. */
function block(selector: string): string {
  const start = css.indexOf(selector);
  if (start < 0) throw new Error(`no ${selector} in theme.css`);
  const open = css.indexOf("{", start);
  let depth = 0;
  for (let i = open; i < css.length; i++) {
    if (css[i] === "{") depth++;
    if (css[i] === "}" && --depth === 0) return css.slice(open + 1, i);
  }
  throw new Error("unbalanced braces");
}

const value = (body: string, name: string) =>
  body.match(new RegExp(`--sf-${kebab(name)}:\\s*#([0-9A-Fa-f]{6})\\s*;`))?.[1].toLowerCase();

describe("theme.css mirrors Theme.swift", () => {
  it("finds the colours", () => {
    expect(colors.length).toBeGreaterThan(20);
  });
  const light = block(":root {");
  const darkAttr = block(':root[data-theme="dark"]');
  const darkMedia = block("@media (prefers-color-scheme: dark)");
  const lightAttr = block(':root[data-theme="light"]');
  for (const c of colors) {
    it(`${c.name} matches`, () => {
      expect(value(light, c.name)).toBe(c.light);
      expect(value(lightAttr, c.name)).toBe(c.light);
      expect(value(darkAttr, c.name)).toBe(c.dark);
      expect(value(darkMedia, c.name)).toBe(c.dark);
    });
  }
  it("maps the shadcn tokens", () => {
    for (const t of ["background", "foreground", "card", "primary", "muted-foreground", "border", "ring"]) {
      expect(light).toMatch(new RegExp(`--${t}:\\s*var\\(--sf-`));
    }
  });
});

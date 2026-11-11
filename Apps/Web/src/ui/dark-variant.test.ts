import { readFileSync } from "node:fs";
import path from "node:path";
import { compile } from "tailwindcss";
import { describe, expect, it } from "vitest";

const css = readFileSync(path.join(import.meta.dirname, "index.css"), "utf8");
const variant = css.match(/@custom-variant dark \{[\s\S]*?\n\}\n/)?.[0];

describe("dark: variant", () => {
  it("is declared in index.css", () => {
    expect(variant).toBeDefined();
  });

  it("covers explicit dark and system dark without a light override", async () => {
    const compiler = await compile(`${variant}\n@tailwind utilities;`);
    const out = compiler.build(["dark:underline"]);
    expect(out).toContain('[data-theme="dark"]');
    expect(out).toMatch(/@media \(prefers-color-scheme: dark\)/);
    expect(out).toContain(':root:not([data-theme="light"])');
    expect(out).toContain("text-decoration-line: underline");
  });
});

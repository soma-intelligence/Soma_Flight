import { assertEquals } from "jsr:@std/assert@1";
import { uuidV5 } from "./board_rows.ts";

Deno.test("uuidV5 matches the RFC 4122 DNS example", async () => {
  assertEquals(
    await uuidV5("www.example.com", "6ba7b810-9dad-11d1-80b4-00c04fd430c8"),
    "2ed6657d-e927-568b-95e1-2665a8aea6a2",
  );
});

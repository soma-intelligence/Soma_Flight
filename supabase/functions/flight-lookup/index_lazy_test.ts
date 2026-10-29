// The deployed entry point must start without AEROAPI_KEY; only a lookup that needs it fails.
import { assertEquals } from "jsr:@std/assert@1";
import {
  loadIndexHandler,
  makeUser,
  test,
  testDb,
  userClient,
} from "../_shared/test_util.ts";

const db = await testDb();
const serve = await loadIndexHandler(
  new URL("./index.ts", import.meta.url).href,
);

const post = (t: string, body: unknown) =>
  new Request("http://local/flight-lookup", {
    method: "POST",
    headers: {
      authorization: `Bearer ${t}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

test(
  db,
  "flight-lookup starts without AEROAPI_KEY; 503 only when AeroAPI is needed",
  async () => {
    const t =
      (await (await userClient(db, await makeUser(db))).auth.getSession())
        .data.session!.access_token;
    const bad = await serve(post(t, { date: "2026-11-03" }));
    assertEquals(bad.status, 400);
    const need = await serve(
      post(t, { ident: "UA1630", date: new Date().toISOString().slice(0, 10) }),
    );
    assertEquals(need.status, 503);
    assertEquals((await need.json()).error.code, "provider_unavailable");
  },
);

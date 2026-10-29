// The deployed entry point must start without AEROAPI_KEY; validation runs without it.
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

test(
  db,
  "follow-flight starts without AEROAPI_KEY and validates the body",
  async () => {
    const t =
      (await (await userClient(db, await makeUser(db))).auth.getSession())
        .data.session!.access_token;
    const res = await serve(
      new Request("http://local/follow-flight", {
        method: "POST",
        headers: {
          authorization: `Bearer ${t}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ flightId: "nope" }),
      }),
    );
    assertEquals(res.status, 400);
  },
);

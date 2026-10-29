// The deployed entry point must start and delete an account without AEROAPI_KEY.
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
  "delete-account starts without AEROAPI_KEY and deletes an account",
  async () => {
    const user = await makeUser(db);
    const c = await userClient(db, user);
    const t = (await c.auth.getSession()).data.session!.access_token;
    const res = await serve(
      new Request("http://local/delete-account", {
        method: "POST",
        headers: { authorization: `Bearer ${t}` },
      }),
    );
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { ok: true });
    const p = await db.from("profiles").select("status").eq("user_id", user)
      .single();
    assertEquals(p.data?.status, "deleted");
  },
);

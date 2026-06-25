import { describe, it, expect } from "vitest";
import { withUser, withService } from "@/db/client";
import { USERS } from "../setup/testdb";

/**
 * Priority 3.13 — the acting identity (app.current_user_id) and the database
 * ROLE are set with SET LOCAL inside a transaction, so they must never leak
 * between concurrent requests sharing the connection pool, and business work
 * must always run as app_user (never service_role).
 */
describe("connection isolation", () => {
  it("each concurrent withUser sees only its own app.current_user_id", async () => {
    const ids = Object.values(USERS);
    // Many interleaved transactions across the pool; each must read back exactly
    // the identity it set — never a neighbour's.
    const tasks = Array.from({ length: 60 }, (_, i) => {
      const want = ids[i % ids.length] as string;
      return withUser(want, async (tx) => {
        const rows = await tx<{ uid: string | null; role: string }[]>`
          select current_setting('app.current_user_id', true) as uid, current_user as role
        `;
        return { want, got: rows[0]?.uid ?? null, role: rows[0]?.role };
      });
    });
    const results = await Promise.all(tasks);
    for (const r of results) {
      expect(r.got).toBe(r.want);
      expect(r.role).toBe("app_user");
    }
  });

  it("the identity does not survive past its transaction (no session bleed)", async () => {
    await withUser(USERS.super, async (tx) => {
      const rows = await tx<{ uid: string | null }[]>`select current_setting('app.current_user_id', true) as uid`;
      expect(rows[0]?.uid).toBe(USERS.super);
    });
    // A fresh transaction with no identity set must see an empty GUC, not the
    // previous user's id.
    const leaked = await withService(async (tx) => {
      const rows = await tx<{ uid: string | null }[]>`select current_setting('app.current_user_id', true) as uid`;
      return rows[0]?.uid ?? "";
    });
    expect(leaked).toBe("");
  });

  it("business transactions run as app_user, never service_role", async () => {
    const role = await withUser(USERS.cashier, async (tx) => {
      const rows = await tx<{ role: string }[]>`select current_user as role`;
      return rows[0]?.role;
    });
    expect(role).toBe("app_user");
  });
});

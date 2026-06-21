import { describe, it, expect } from "vitest";
import { middlewareDecision, homePathForRole, isPublicPath } from "@/lib/auth/redirect";

describe("auth routing logic (middleware + redirects)", () => {
  it("redirects unauthenticated users away from protected routes", () => {
    expect(middlewareDecision("/", false)).toBe("/login");
    expect(middlewareDecision("/demandes", false)).toBe("/login");
    expect(middlewareDecision("/tresorerie", false)).toBe("/login");
    expect(middlewareDecision("/plus", false)).toBe("/login");
  });

  it("lets authenticated users through protected routes", () => {
    expect(middlewareDecision("/", true)).toBeNull();
    expect(middlewareDecision("/historique", true)).toBeNull();
  });

  it("keeps the login page public and bounces authenticated users home", () => {
    expect(isPublicPath("/login")).toBe(true);
    expect(middlewareDecision("/login", false)).toBeNull();
    expect(middlewareDecision("/login", true)).toBe("/");
  });

  it("computes the post-login home path for every role", () => {
    for (const role of ["super_admin", "first_validator", "operations_director", "cashier", "accountant"] as const) {
      expect(homePathForRole(role)).toBe("/");
    }
  });
});

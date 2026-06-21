/**
 * Pure routing decisions (edge-safe, no imports). Unit-tested directly.
 */
import type { RoleCode } from "@/lib/types";

/** Post-login landing path for a role. Phase 2: all roles land on Accueil. */
export function homePathForRole(_role: RoleCode | string): string {
  return "/";
}

/** Routes reachable without a session. */
export function isPublicPath(pathname: string): boolean {
  return pathname === "/login";
}

/**
 * Coarse cookie-existence gate for middleware. Real validation happens
 * server-side (DB) in the protected layout.
 *   - on a public path with a session  -> go home
 *   - on a protected path with no cookie -> go to login
 *   - otherwise -> allow (null)
 */
export function middlewareDecision(pathname: string, hasSession: boolean): string | null {
  if (isPublicPath(pathname)) return hasSession ? "/" : null;
  return hasSession ? null : "/login";
}

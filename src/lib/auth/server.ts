import "server-only";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import * as auth from "@/services/auth.service";
import { SESSION_COOKIE } from "@/lib/auth/constants";
import type { CurrentUser } from "@/lib/types";

export function sessionCookieOptions(expires?: Date) {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax" as const,
    path: "/",
    ...(expires ? { expires } : {}),
  };
}

/** Resolve the current user from the session cookie (or null). DB-backed. */
export async function getCurrentUserOrNull(): Promise<CurrentUser | null> {
  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  const uid = await auth.getSessionUserId(token);
  if (!uid) return null;
  try {
    return await auth.getCurrentUser(uid);
  } catch {
    return null;
  }
}

/** For protected layouts/pages: load the user or redirect to /login. */
export async function requireUser(): Promise<CurrentUser> {
  const user = await getCurrentUserOrNull();
  if (!user) redirect("/login");
  return user;
}

"use server";
import { cookies, headers } from "next/headers";
import * as auth from "@/services/auth.service";
import { loginSchema } from "@/lib/schemas";
import { SESSION_COOKIE } from "@/lib/auth/constants";
import { sessionCookieOptions } from "@/lib/auth/server";
import { homePathForRole } from "@/lib/auth/redirect";
import { AppError } from "@/db/errors";

type LoginResult = { ok: true; redirectTo: string } | { ok: false; error: string };

/** Authenticate, set the httpOnly session cookie, return the role-based path. */
export async function loginAction(input: { email: string; password: string }): Promise<LoginResult> {
  const parsed = loginSchema.safeParse(input);
  if (!parsed.success) return { ok: false, error: "E-mail ou mot de passe invalide." };
  try {
    const h = await headers();
    const res = await auth.login(parsed.data, {
      ip: h.get("x-forwarded-for") ?? undefined,
      userAgent: h.get("user-agent") ?? undefined,
    });
    (await cookies()).set(SESSION_COOKIE, res.token, sessionCookieOptions(res.expiresAt));
    return { ok: true, redirectTo: homePathForRole(res.user.role) };
  } catch (e) {
    return { ok: false, error: e instanceof AppError ? e.message : "Une erreur est survenue. Veuillez réessayer." };
  }
}

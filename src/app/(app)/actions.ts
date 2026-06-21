"use server";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import * as auth from "@/services/auth.service";
import { SESSION_COOKIE } from "@/lib/auth/constants";

/** Revoke the session and clear the cookie, then return to the login page. */
export async function logoutAction(): Promise<void> {
  const c = await cookies();
  const token = c.get(SESSION_COOKIE)?.value;
  if (token) await auth.logout(token);
  c.delete(SESSION_COOKIE);
  redirect("/login");
}

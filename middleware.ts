import { NextResponse, type NextRequest } from "next/server";
import { SESSION_COOKIE } from "@/lib/auth/constants";
import { middlewareDecision } from "@/lib/auth/redirect";

/**
 * Coarse cookie-existence gate. Real session validation happens server-side
 * (DB) in the protected layout — middleware never touches pg / server-only.
 */
export function middleware(req: NextRequest) {
  const hasSession = Boolean(req.cookies.get(SESSION_COOKIE)?.value);
  const target = middlewareDecision(req.nextUrl.pathname, hasSession);
  if (target && target !== req.nextUrl.pathname) {
    return NextResponse.redirect(new URL(target, req.url));
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|manifest.webmanifest|icons|.*\\.png$).*)"],
};

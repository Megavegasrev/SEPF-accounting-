/** Edge-safe constants (no DB / no server-only imports — usable in middleware). */
export const SESSION_COOKIE = process.env.SESSION_COOKIE_NAME ?? "sepf_session";

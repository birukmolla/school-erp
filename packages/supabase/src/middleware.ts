import { createSupabaseServerClient } from "./server";
import type { SupabaseCookieAdapter } from "./server";

/**
 * Refreshes/validates the current Supabase session against Supabase Auth.
 *
 * Deliberately framework-agnostic: no next/server, no NextRequest/NextResponse
 * imports here. This file exists specifically so the identical piece of logic
 * every app's middleware.ts needs (construct a Supabase server client from a
 * cookie adapter, call getUser()) isn't hand-copied five times.
 *
 * The genuinely Next.js-specific part -- building a NextResponse, threading
 * request/response cookies through it -- stays in each app's own
 * middleware.ts, per this project's rule that Next-specific code never lives
 * inside this shared package.
 *
 * Always uses getUser(), never getSession(). getSession() trusts the JWT
 * embedded in the cookie without revalidating it against Supabase Auth --
 * fine for optimistic UI state, never fine for anything security-relevant.
 * Session refresh in middleware is exactly the kind of place a stale/forged
 * cookie should not be trusted, so getUser() is the only correct choice here.
 */
export async function refreshSupabaseSession(
  supabaseUrl: string,
  supabasePublishableKey: string,
  cookieAdapter: SupabaseCookieAdapter
): Promise<void> {
  const supabase = createSupabaseServerClient(
    supabaseUrl,
    supabasePublishableKey,
    cookieAdapter
  );

  await supabase.auth.getUser();
}
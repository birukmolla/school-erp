import { NextResponse, type NextRequest } from "next/server";
import { refreshSupabaseSession } from "@school-erp/supabase/middleware";

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({
    request,
  });

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const supabasePublishableKey =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (!supabaseUrl) {
    throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL");
  }

  if (!supabasePublishableKey) {
    throw new Error("Missing NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");
  }

  // Refresh/validate the Supabase session via the shared, framework-agnostic
  // helper in @school-erp/supabase. This block -- constructing the request/
  // response cookie adapter -- is the one part of session refresh that is
  // genuinely Next.js-specific (NextRequest/NextResponse are middleware-only
  // APIs) and therefore stays here rather than in the shared package.
  await refreshSupabaseSession(supabaseUrl, supabasePublishableKey, {
    getAll() {
      return request.cookies.getAll();
    },

    setAll(cookiesToSet) {
      cookiesToSet.forEach(({ name, value }) => {
        request.cookies.set(name, value);
      });

      response = NextResponse.next({
        request,
      });

      cookiesToSet.forEach(({ name, value, options }) => {
        response.cookies.set(name, value, options);
      });
    },
  });

  return response;
}

export const config = {
  matcher: [
    /*
     * Run middleware on application routes while
     * excluding Next.js internals and common static files.
     */
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
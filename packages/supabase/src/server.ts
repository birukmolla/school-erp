import { createServerClient } from "@supabase/ssr";
import type { CookieOptions } from "@supabase/ssr";

export interface SupabaseCookieAdapter {
  getAll(): {
    name: string;
    value: string;
  }[];

  setAll(
    cookies: {
      name: string;
      value: string;
      options?: CookieOptions;
    }[]
  ): void;
}

export function createSupabaseServerClient(
  supabaseUrl: string,
  supabasePublishableKey: string,
  cookieAdapter: SupabaseCookieAdapter
) {
  return createServerClient(
    supabaseUrl,
    supabasePublishableKey,
    {
      cookies: cookieAdapter,
    }
  );
}
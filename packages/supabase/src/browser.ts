import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";

export function createSupabaseBrowserClient(
  supabaseUrl: string,
  supabasePublishableKey: string
): SupabaseClient {
  return createBrowserClient(
    supabaseUrl,
    supabasePublishableKey
  );
}
/// <reference types="astro/client" />

declare namespace App {
  interface Locals {
    supabase: ReturnType<typeof import('./lib/supabase').createSupabaseClient>;
  }
}

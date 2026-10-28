// Editor-only shims for the Supabase Edge Functions.
//
// The functions run on Deno and import from esm.sh by URL. A Deno CLI resolves
// both natively; the IDE's TypeScript server does not, and reports
// "Cannot find name 'Deno'" / "Cannot find module 'https://esm.sh/...'".
// Declaring the small surface actually used keeps the editor honest without
// pulling a toolchain in, and changes nothing at deploy time — Deno ignores
// these declarations in favour of its own lib.deno.d.ts.

declare namespace Deno {
  function serve(
    handler: (request: Request) => Response | Promise<Response>,
  ): void;
  const env: {
    get(key: string): string | undefined;
  };
}

declare module 'https://esm.sh/@supabase/supabase-js@2.39.0' {
  export function createClient(
    url: string,
    key: string,
    options?: Record<string, unknown>,
  ): any;
}

declare module 'https://esm.sh/@noble/curves@1.4.0/ed25519' {
  export const ed25519: any;
}

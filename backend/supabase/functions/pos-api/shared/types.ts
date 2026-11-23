export interface Ctx {
  customerId: string;
  userId: string;
  role: string;
  canSeePicklistMoney: boolean;
  deviceId: string | null;
}

export type AnyDb = any; // Supabase client — kept loose for Deno compatibility

export type ApiResponse<T = unknown> = Promise<Response>;

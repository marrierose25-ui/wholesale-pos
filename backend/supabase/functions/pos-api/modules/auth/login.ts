// Auth action handlers live in shared/auth.ts (they own the session/JWT and
// credential machinery); this barrel keeps the module boundary explicit.
export {
  changePassword,
  hasUsers,
  login,
  setupOwner,
} from "../../shared/auth.ts";

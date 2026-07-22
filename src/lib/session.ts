import { supabase } from './supabase';

export type Role = 'participant' | 'arbitre' | 'admin';
export type Session = { username: string; role: Role };

const SESSION_KEY = 'slick_lough_session';

// Each role maps to one shared Supabase Auth account (see supabase-schema.sql
// § role_locks). The password is the real secret; these addresses are just
// fixed identifiers — nothing is ever sent to them.
const ROLE_EMAILS: Record<Role, string> = {
  admin: 'admin@slicklough.internal',
  arbitre: 'arbitre@slicklough.internal',
  participant: 'participant@slicklough.internal',
};

export function getSession(): Session | null {
  try { return JSON.parse(localStorage.getItem(SESSION_KEY) as string); } catch { return null; }
}

function setSession(s: Session): void {
  localStorage.setItem(SESSION_KEY, JSON.stringify(s));
}

// Signs in against the shared Supabase Auth account for that role. On success,
// stores {username, role} for display/UI gating — the real security boundary
// is the Supabase Auth session (JWT), which supabase-js persists and refreshes
// automatically, and which RLS policies check on every write.
export async function login(role: Role, username: string, password: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const { error } = await supabase.auth.signInWithPassword({ email: ROLE_EMAILS[role], password });
  if (error) return { ok: false, error: 'Mot de passe incorrect.' };
  setSession({ username, role });
  return { ok: true };
}

export async function clearSession(): Promise<void> {
  localStorage.removeItem(SESSION_KEY);
  await supabase.auth.signOut();
}

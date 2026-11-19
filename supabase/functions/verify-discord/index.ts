// DRAW ROOM: checks the signed-in person's roles in the Linear Discord server
// and writes the result to public.members.
//
// Secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   DISCORD_GUILD_ID         the Linear Discord server ID
//   DISCORD_LIVER_ROLE_IDS   role IDs that may draw (comma separated)
//   DISCORD_STAFF_ROLE_IDS   role IDs for staff (comma separated)
//   ALLOWED_ORIGIN           optional, e.g. https://isumiaki.github.io  (default: *)
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.

import { createClient } from "npm:@supabase/supabase-js@2";

const DISCORD = "https://discord.com/api/v10";

const list = (v: string | undefined) =>
  (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);

Deno.serve(async (req) => {
  const cors = {
    "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") || "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, reason: "method" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const guild = Deno.env.get("DISCORD_GUILD_ID") ?? "";
  const liverRoles = list(Deno.env.get("DISCORD_LIVER_ROLE_IDS"));
  const staffRoles = list(Deno.env.get("DISCORD_STAFF_ROLE_IDS"));
  if (!guild || (!liverRoles.length && !staffRoles.length)) {
    return json({ ok: false, reason: "not_configured" }, 500);
  }

  // 1. Who is calling (Supabase session)
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return json({ ok: false, reason: "not_signed_in" }, 401);

  const body = await req.json().catch(() => ({}));
  const token = typeof body?.provider_token === "string" ? body.provider_token : "";
  if (!token) return json({ ok: false, reason: "no_token" }, 400);
  const discordHeaders = { Authorization: `Bearer ${token}` };

  // 2. The Discord token must belong to the same Discord account the session signed in with
  const meRes = await fetch(`${DISCORD}/users/@me`, { headers: discordHeaders });
  if (!meRes.ok) return json({ ok: false, reason: "discord_error" }, 400);
  const du = await meRes.json();
  const linked = user.identities?.find((i) => i.provider === "discord");
  const linkedId = String(linked?.identity_data?.provider_id ?? linked?.id ?? user.user_metadata?.provider_id ?? "");
  if (!linkedId || linkedId !== String(du.id)) return json({ ok: false, reason: "mismatch" }, 403);

  const admin = createClient(url, service);
  const deactivate = () =>
    admin.from("members").update({ active: false, verified_at: new Date().toISOString() }).eq("user_id", user.id);

  // 3. Membership and roles in the Linear server
  const memRes = await fetch(`${DISCORD}/users/@me/guilds/${guild}/member`, { headers: discordHeaders });
  if (memRes.status === 404 || memRes.status === 403) {
    await deactivate();
    return json({ ok: false, reason: "not_in_guild" });
  }
  if (!memRes.ok) return json({ ok: false, reason: "discord_error" }, 502);
  const member = await memRes.json();
  const roles: string[] = Array.isArray(member.roles) ? member.roles : [];
  const role = roles.some((r) => staffRoles.includes(r)) ? "staff"
    : roles.some((r) => liverRoles.includes(r)) ? "liver"
    : null;
  if (!role) {
    await deactivate();
    return json({ ok: false, reason: "no_role" });
  }

  // 4. Save (iriam_id is left as it is)
  const name = member.nick || du.global_name || du.username || "";
  const avatar = du.avatar ? `https://cdn.discordapp.com/avatars/${du.id}/${du.avatar}.png?size=64` : null;
  const { error: upErr } = await admin.from("members").upsert({
    user_id: user.id,
    discord_id: String(du.id),
    display_name: String(name).slice(0, 64),
    avatar_url: avatar,
    role,
    active: true,
    verified_at: new Date().toISOString(),
  }, { onConflict: "user_id" });
  if (upErr) return json({ ok: false, reason: "save_failed" }, 500);

  return json({ ok: true, role });
});

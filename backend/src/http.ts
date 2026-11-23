import type { FastifyRequest } from "fastify";
import { and, eq, sql } from "drizzle-orm";
import type { z } from "zod";
import type { Db } from "./db/client.js";
import { groupMembers, tripListings, tripMembers, trips } from "./db/schema.js";

export class HttpError extends Error {
  constructor(
    public statusCode: number,
    public code: string,
    message: string,
  ) {
    super(message);
  }
}

export const notFound = (what = "Nicht gefunden.") => new HttpError(404, "not_found", what);
export const forbidden = (msg = "Dafür fehlt die Berechtigung.") => new HttpError(403, "forbidden", msg);

export function parseBody<T extends z.ZodTypeAny>(schema: T, body: unknown): z.infer<T> {
  const result = schema.safeParse(body ?? {});
  if (!result.success) {
    const issue = result.error.issues[0];
    throw new HttpError(400, "invalid_request", `${issue?.path.join(".") || "Eingabe"}: ${issue?.message ?? "ungültig"}`);
  }
  return result.data;
}

export function userId(req: FastifyRequest): string {
  if (!req.user) throw new HttpError(401, "unauthorized", "Anmeldung erforderlich.");
  return req.user.id;
}

export type Role = "organizer" | "member" | "guest";
const rank: Record<Role, number> = { guest: 0, member: 1, organizer: 2 };

/** Who administers a group runs its trips as well: the role counts as organizer there. The shared shelf has no organizer rights to gain. The outer columns are spelled out because a single-table select leaves them unqualified. */
export const runsTrip = sql<boolean>`exists (select 1 from ${trips} t join ${groupMembers} gm on gm.group_id = t.group_id where t.id = "trip_members"."trip_id" and t.kind <> 'watchlist' and gm.user_id = "trip_members"."user_id" and gm.role = 'admin')`;
export const effectiveRole = (role: Role, runs: boolean): Role => (runs && role !== "guest" ? "organizer" : role);

/** Every trip request is checked against membership; a missing trip and a foreign trip look the same. */
export async function requireMember(db: Db, tripId: string, uid: string, minimum: Role = "guest"): Promise<Role> {
  const [m] = await db
    .select({ role: tripMembers.role, runs: runsTrip })
    .from(tripMembers)
    .where(and(eq(tripMembers.tripId, tripId), eq(tripMembers.userId, uid)))
    .limit(1);
  if (!m) throw notFound("Reise nicht gefunden.");
  const role = effectiveRole(m.role, m.runs);
  if (rank[role] < rank[minimum]) throw forbidden();
  return role;
}

export async function requireCandidate(db: Db, candidateId: string, uid: string, minimum: Role = "guest") {
  const [c] = await db.select().from(tripListings).where(eq(tripListings.id, candidateId)).limit(1);
  if (!c) throw notFound("Angebot nicht gefunden.");
  const role = await requireMember(db, c.tripId, uid, minimum).catch((e) => {
    throw e instanceof HttpError && e.statusCode === 404 ? notFound("Angebot nicht gefunden.") : e;
  });
  return { candidate: c, role };
}

export const uuidParam = (v: unknown): string => {
  if (typeof v !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)) throw notFound();
  return v;
};

declare module "fastify" {
  interface FastifyRequest {
    user: { id: string; name: string; sessionId: string } | null;
  }
}

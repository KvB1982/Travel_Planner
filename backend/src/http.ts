import type { FastifyRequest } from "fastify";
import { and, eq } from "drizzle-orm";
import type { z } from "zod";
import type { Db } from "./db/client.js";
import { tripListings, tripMembers } from "./db/schema.js";

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

/** Every trip request is checked against membership; a missing trip and a foreign trip look the same. */
export async function requireMember(db: Db, tripId: string, uid: string, minimum: Role = "guest"): Promise<Role> {
  const [m] = await db
    .select({ role: tripMembers.role })
    .from(tripMembers)
    .where(and(eq(tripMembers.tripId, tripId), eq(tripMembers.userId, uid)))
    .limit(1);
  if (!m) throw notFound("Reise nicht gefunden.");
  if (rank[m.role] < rank[minimum]) throw forbidden();
  return m.role;
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

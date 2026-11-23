CREATE TABLE "group_members" (
	"group_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"role" text DEFAULT 'member' NOT NULL,
	"joined_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "group_members_group_id_user_id_pk" PRIMARY KEY("group_id","user_id")
);
--> statement-breakpoint
CREATE TABLE "groups" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"name" text NOT NULL,
	"created_by" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "invites" ALTER COLUMN "trip_id" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "group_id" uuid;--> statement-breakpoint
ALTER TABLE "trips" ADD COLUMN "group_id" uuid;--> statement-breakpoint
ALTER TABLE "group_members" ADD CONSTRAINT "group_members_group_id_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "group_members" ADD CONSTRAINT "group_members_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "groups" ADD CONSTRAINT "groups_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
-- Everyone who has an account at this point travels together: one group for all of them and all their trips.
INSERT INTO "groups" ("name", "created_by") SELECT 'Unsere Gruppe', (SELECT "id" FROM "users" ORDER BY "created_at" LIMIT 1) WHERE EXISTS (SELECT 1 FROM "users");--> statement-breakpoint
INSERT INTO "group_members" ("group_id", "user_id", "role") SELECT g."id", u."id", CASE WHEN u."id" = g."created_by" THEN 'admin' ELSE 'member' END FROM "groups" g CROSS JOIN "users" u;--> statement-breakpoint
UPDATE "trips" SET "group_id" = (SELECT "id" FROM "groups" LIMIT 1) WHERE "kind" = 'trip';--> statement-breakpoint
INSERT INTO "trip_members" ("trip_id", "user_id", "role") SELECT t."id", u."id", 'member' FROM "trips" t CROSS JOIN "users" u WHERE t."kind" = 'trip' ON CONFLICT DO NOTHING;

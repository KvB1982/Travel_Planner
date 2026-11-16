CREATE TABLE "trip_criteria" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"trip_id" uuid NOT NULL,
	"key" text NOT NULL,
	"label" text,
	"level" text DEFAULT 'wish' NOT NULL,
	"target" double precision,
	"position" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "trip_listings" ADD COLUMN "criteria_checks" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "trip_criteria" ADD CONSTRAINT "trip_criteria_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "trip_criteria_trip_idx" ON "trip_criteria" USING btree ("trip_id","position");
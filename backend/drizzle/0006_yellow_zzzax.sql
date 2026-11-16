CREATE TABLE "trip_rankings" (
	"trip_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"order" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "trip_rankings_trip_id_user_id_pk" PRIMARY KEY("trip_id","user_id")
);
--> statement-breakpoint
ALTER TABLE "trip_listings" ADD COLUMN "finalist" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "trips" ADD COLUMN "phase" text DEFAULT 'research' NOT NULL;--> statement-breakpoint
ALTER TABLE "trips" ADD COLUMN "decided_candidate_id" uuid;--> statement-breakpoint
ALTER TABLE "trips" ADD COLUMN "decided_date_option_id" uuid;--> statement-breakpoint
ALTER TABLE "trips" ADD COLUMN "decided_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "trip_rankings" ADD CONSTRAINT "trip_rankings_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "trip_rankings" ADD CONSTRAINT "trip_rankings_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
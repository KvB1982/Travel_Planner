CREATE TABLE "source_suggestions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"trip_listing_id" uuid NOT NULL,
	"url" text NOT NULL,
	"platform" text NOT NULL,
	"title" text,
	"reason" text,
	"confidence" text DEFAULT 'medium' NOT NULL,
	"status" text DEFAULT 'proposed' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "listing_sources" ADD COLUMN "extract" jsonb;--> statement-breakpoint
ALTER TABLE "trip_listings" ADD COLUMN "search_status" text DEFAULT 'idle' NOT NULL;--> statement-breakpoint
ALTER TABLE "trip_listings" ADD COLUMN "searched_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "trip_listings" ADD COLUMN "search_note" text;--> statement-breakpoint
ALTER TABLE "source_suggestions" ADD CONSTRAINT "source_suggestions_trip_listing_id_trip_listings_id_fk" FOREIGN KEY ("trip_listing_id") REFERENCES "public"."trip_listings"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "source_suggestions_candidate_url_idx" ON "source_suggestions" USING btree ("trip_listing_id","url");
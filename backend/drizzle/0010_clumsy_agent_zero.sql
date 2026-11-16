CREATE TABLE "house_info" (
	"trip_id" uuid PRIMARY KEY NOT NULL,
	"address" text,
	"lat" double precision,
	"lon" double precision,
	"check_in_from" text,
	"check_out_until" text,
	"key_info" text,
	"wifi_name" text,
	"wifi_password" text,
	"contact_name" text,
	"contact_phone" text,
	"rules" text,
	"waste" text,
	"emergency" text,
	"notes" text,
	"updated_by" uuid,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "house_info" ADD CONSTRAINT "house_info_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "house_info" ADD CONSTRAINT "house_info_updated_by_users_id_fk" FOREIGN KEY ("updated_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
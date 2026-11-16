CREATE TABLE "booking_payments" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"booking_id" uuid NOT NULL,
	"label" text NOT NULL,
	"amount_cents" integer NOT NULL,
	"due_on" date,
	"paid_on" date,
	"paid_by_party" uuid,
	"refundable" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "bookings" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"trip_id" uuid NOT NULL,
	"kind" text DEFAULT 'accommodation' NOT NULL,
	"title" text NOT NULL,
	"provider" text,
	"reference" text,
	"candidate_id" uuid,
	"status" text DEFAULT 'planned' NOT NULL,
	"starts_at" text,
	"ends_at" text,
	"place" text,
	"total_cents" integer,
	"deposit_cents" integer,
	"deposit_returned_on" date,
	"free_cancellation_until" date,
	"booked_by_party" uuid,
	"notes" text,
	"created_by" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "checklist_items" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"trip_id" uuid NOT NULL,
	"list" text DEFAULT 'packing' NOT NULL,
	"title" text NOT NULL,
	"quantity" text,
	"assigned_to" uuid,
	"assigned_party" uuid,
	"due_on" date,
	"done" boolean DEFAULT false NOT NULL,
	"done_by" uuid,
	"done_at" timestamp with time zone,
	"private" boolean DEFAULT false NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"created_by" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "documents" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"trip_id" uuid NOT NULL,
	"booking_id" uuid,
	"title" text NOT NULL,
	"kind" text,
	"content_type" text NOT NULL,
	"size_bytes" integer NOT NULL,
	"stored_name" text NOT NULL,
	"uploaded_by" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "booking_payments" ADD CONSTRAINT "booking_payments_booking_id_bookings_id_fk" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bookings" ADD CONSTRAINT "bookings_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bookings" ADD CONSTRAINT "bookings_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "checklist_items" ADD CONSTRAINT "checklist_items_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "checklist_items" ADD CONSTRAINT "checklist_items_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "documents" ADD CONSTRAINT "documents_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "documents" ADD CONSTRAINT "documents_booking_id_bookings_id_fk" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "documents" ADD CONSTRAINT "documents_uploaded_by_users_id_fk" FOREIGN KEY ("uploaded_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "booking_payments_booking_idx" ON "booking_payments" USING btree ("booking_id");--> statement-breakpoint
CREATE INDEX "bookings_trip_idx" ON "bookings" USING btree ("trip_id");--> statement-breakpoint
CREATE INDEX "checklist_items_trip_idx" ON "checklist_items" USING btree ("trip_id","list","position");--> statement-breakpoint
CREATE INDEX "documents_trip_idx" ON "documents" USING btree ("trip_id");
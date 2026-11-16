ALTER TABLE "checklist_items" ADD COLUMN "client_id" uuid;--> statement-breakpoint
ALTER TABLE "expenses" ADD COLUMN "client_id" uuid;--> statement-breakpoint
CREATE UNIQUE INDEX "checklist_items_client_idx" ON "checklist_items" USING btree ("trip_id","client_id");--> statement-breakpoint
CREATE UNIQUE INDEX "expenses_client_idx" ON "expenses" USING btree ("trip_id","client_id");
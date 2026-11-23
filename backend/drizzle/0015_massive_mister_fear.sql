DROP INDEX "trips_watchlist_owner_idx";--> statement-breakpoint
CREATE UNIQUE INDEX "trips_watchlist_group_idx" ON "trips" USING btree ("group_id") WHERE "trips"."kind" = 'watchlist';--> statement-breakpoint
CREATE UNIQUE INDEX "trips_watchlist_owner_idx" ON "trips" USING btree ("created_by") WHERE "trips"."kind" = 'watchlist' and "trips"."group_id" is null;
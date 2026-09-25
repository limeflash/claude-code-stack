// claude-mem enqueues every mutation into sync_outbox unconditionally, but only
// drains it when cloud sync is configured (token + user + hub). Without cloud
// sync the queue only grows: 3.6M rows / 1.2 GB in six weeks, against ~120 MB
// of actual memory. Nothing references the table.
//
// Refuses to touch anything when cloud sync IS configured -- then the queue is
// real pending work, not garbage.
import { Database } from "bun:sqlite";
import { readFileSync } from "fs";

const home = process.env.USERPROFILE ?? process.env.HOME!;
const s = JSON.parse(readFileSync(home + "/.claude-mem/settings.json", "utf8").replace(/^﻿/, ""));
if ((s.CLAUDE_MEM_CLOUD_SYNC_TOKEN ?? "") !== "" || (s.CLAUDE_MEM_CLOUD_SYNC_HUB_URL ?? "").trim() !== "") {
  console.log("cloud sync configured -- outbox left alone");
  process.exit(0);
}
const db = new Database(home + "/.claude-mem/claude-mem.db");
db.exec("PRAGMA busy_timeout=30000");
const n = db.run("DELETE FROM sync_outbox").changes;
console.log(`pruned ${n} outbox rows`);

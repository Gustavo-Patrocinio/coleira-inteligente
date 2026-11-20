// GET /health/backups logic: newest local dump and the off-site marker, both under 48 h.
import { mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { backupStatus } from "../src/backups.js";

const H = 3_600_000;
const now = Date.parse("2026-11-20T12:00:00Z");
let dir: string;

async function file(name: string, ageH: number, body = "dump") {
  const p = join(dir, name);
  await writeFile(p, body);
  const t = (now - ageH * H) / 1000;
  await utimes(p, t, t);
}

describe("backupStatus", () => {
  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  it("fresh dump and fresh off-site copy: ok", async () => {
    dir = await mkdtemp(join(tmpdir(), "bk-"));
    await file("collar-2026-11-18.dump", 50);
    await file("collar-2026-11-20.dump", 3);
    await file(".offsite-ok", 1);
    expect(await backupStatus(dir, now)).toEqual({ ok: true, local_age_h: 3, offsite_age_h: 1, problems: [] });
  });

  it("off-site never set up only checks the local dumps", async () => {
    dir = await mkdtemp(join(tmpdir(), "bk-"));
    await file("collar-2026-11-20.dump", 10);
    const s = await backupStatus(dir, now);
    expect(s.ok).toBe(true);
    expect(s.offsite_age_h).toBeNull();
  });

  it("stale dump, stale off-site copy, empty or missing dumps are problems", async () => {
    dir = await mkdtemp(join(tmpdir(), "bk-"));
    await file("collar-2026-11-17.dump", 72);
    await file("collar-2026-11-20.dump", 1, ""); // an empty file is not a backup
    await file("notes.txt", 0);
    await file(".offsite-ok", 60);
    const s = await backupStatus(dir, now);
    expect(s.ok).toBe(false);
    expect(s.problems).toEqual(["newest backup is 72 h old", "last off-site copy was 60 h ago"]);

    await rm(join(dir, "collar-2026-11-17.dump"));
    expect((await backupStatus(dir, now)).problems[0]).toBe("no backup yet");
    expect((await backupStatus(join(dir, "missing"), now)).problems).toEqual(["backup folder not readable"]);
  });
});

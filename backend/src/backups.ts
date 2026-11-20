/**
 * Are the backups still happening? The deploy's backup service writes one pg_dump a day to
 * BACKUP_DIR (collar-YYYY-MM-DD.dump) and the optional offsite service touches
 * `.offsite-ok` there after each successful encrypted upload. GET /health/backups reports
 * both, so the Uptime workflow emails the owner when either stops, instead of the owner
 * finding out on the day a restore is needed.
 */
import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";

/** A daily job is late after two days (one missed night plus slack). */
export const MAX_AGE_H = 48;

export interface BackupStatus {
  ok: boolean;
  /** hours since the newest local dump; null = none yet */
  local_age_h: number | null;
  /** hours since the last off-site upload; null = off-site copies not set up */
  offsite_age_h: number | null;
  problems: string[];
}

const hours = (ms: number) => Math.round((ms / 3_600_000) * 10) / 10;

export async function backupStatus(dir: string, now = Date.now()): Promise<BackupStatus> {
  const problems: string[] = [];
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return { ok: false, local_age_h: null, offsite_age_h: null, problems: ["backup folder not readable"] };
  }

  let newest: number | null = null;
  for (const n of names) {
    if (!/^collar-.*\.dump$/.test(n)) continue;
    const s = await stat(join(dir, n));
    if (s.size > 0 && (newest === null || s.mtimeMs > newest)) newest = s.mtimeMs;
  }
  const local = newest === null ? null : hours(now - newest);
  if (local === null) problems.push("no backup yet");
  else if (local > MAX_AGE_H) problems.push(`newest backup is ${Math.floor(local)} h old`);

  let offsite: number | null = null;
  if (names.includes(".offsite-ok")) {
    offsite = hours(now - (await stat(join(dir, ".offsite-ok"))).mtimeMs);
    if (offsite > MAX_AGE_H) problems.push(`last off-site copy was ${Math.floor(offsite)} h ago`);
  }

  return { ok: problems.length === 0, local_age_h: local, offsite_age_h: offsite, problems };
}

/**
 * Push notifications through Firebase Cloud Messaging (HTTP v1 API), with no SDK: a service
 * account signs a JWT (RS256, node:crypto), Google exchanges it for an access token, and each
 * message is one POST. Enabled only when FCM_SERVICE_ACCOUNT_FILE is set (backend/DEPLOY.md).
 */
import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import type pg from "pg";

export interface PushMessage {
  title: string;
  body: string;
  data?: Record<string, string>;
}

/** `unregistered`: the token is gone for good (app uninstalled, token rotated) → delete it. */
export type PushResult = "ok" | "unregistered" | "error";

export interface PushSender {
  send(token: string, msg: PushMessage): Promise<PushResult>;
}

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

export class FcmSender implements PushSender {
  private accessToken?: { value: string; expires: number };

  constructor(
    private readonly sa: ServiceAccount,
    private readonly fetchFn: typeof fetch = fetch,
    private readonly now: () => number = Date.now,
  ) {}

  static fromFile(path: string): FcmSender {
    return new FcmSender(JSON.parse(readFileSync(path, "utf8")) as ServiceAccount);
  }

  private async token(): Promise<string> {
    if (this.accessToken && this.accessToken.expires > this.now() + 60_000) return this.accessToken.value;
    const iat = Math.floor(this.now() / 1000);
    const tokenUri = this.sa.token_uri ?? "https://oauth2.googleapis.com/token";
    const unsigned = `${b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64url(
      JSON.stringify({
        iss: this.sa.client_email,
        scope: "https://www.googleapis.com/auth/firebase.messaging",
        aud: tokenUri,
        iat,
        exp: iat + 3600,
      }),
    )}`;
    const signature = createSign("RSA-SHA256").update(unsigned).sign(this.sa.private_key);
    const res = await this.fetchFn(tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: `${unsigned}.${b64url(signature)}`,
      }),
    });
    if (!res.ok) throw new Error(`FCM auth failed: ${res.status}`);
    const j = (await res.json()) as { access_token: string; expires_in: number };
    this.accessToken = { value: j.access_token, expires: this.now() + j.expires_in * 1000 };
    return j.access_token;
  }

  async send(token: string, msg: PushMessage): Promise<PushResult> {
    const res = await this.fetchFn(`https://fcm.googleapis.com/v1/projects/${this.sa.project_id}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${await this.token()}`, "content-type": "application/json" },
      body: JSON.stringify({
        message: { token, notification: { title: msg.title, body: msg.body }, data: msg.data ?? {} },
      }),
    });
    if (res.ok) return "ok";
    // 404 UNREGISTERED, or 400 for a malformed token: either way it will never work
    if (res.status === 404 || res.status === 400) return "unregistered";
    return "error";
  }
}

/**
 * Lock-screen text: says what changed in plain words, no numbers, no medical claim; the
 * details (and "talk to your vet" when it applies) are in the app.
 */
export function alertPushText(metric: string, direction: string, dogName: string): PushMessage {
  const what =
    metric === "scratching"
      ? "scratched more than usual"
      : metric === "night_wakeups"
        ? "had a restless night"
        : direction === "low"
          ? "was less active than usual"
          : "was more active than usual";
  return { title: `${dogName} ${what}`, body: "Open the app to see how it compares with the normal." };
}

/**
 * Sends one notification per alert not yet notified (only recent days, so turning push on
 * later does not flood old alerts) and marks it. Tokens FCM reports as gone are deleted.
 */
export async function notifyNewAlerts(
  pool: pg.Pool,
  push: PushSender,
  sinceDay: string,
): Promise<{ sent: number; removedTokens: number }> {
  const pending = (
    await pool.query<{ id: string; dog_id: string; metric: string; direction: string; name: string; user_id: string }>(
      `SELECT a.id, a.dog_id, a.metric, a.direction, g.name, g.user_id
         FROM alerts a JOIN dogs g ON g.id = a.dog_id
        WHERE a.notified_at IS NULL AND a.day >= $1
        ORDER BY a.id`,
      [sinceDay],
    )
  ).rows;
  let sent = 0;
  let removedTokens = 0;
  for (const a of pending) {
    const tokens = (await pool.query<{ token: string }>("SELECT token FROM push_tokens WHERE user_id = $1", [a.user_id]))
      .rows;
    const msg = { ...alertPushText(a.metric, a.direction, a.name), data: { alert_id: a.id, dog_id: a.dog_id } };
    for (const { token } of tokens) {
      const r = await push.send(token, msg);
      if (r === "ok") sent++;
      if (r === "unregistered") {
        await pool.query("DELETE FROM push_tokens WHERE token = $1", [token]);
        removedTokens++;
      }
    }
    // marked even with no phone registered: the alert is in the app; a later push would be stale
    await pool.query("UPDATE alerts SET notified_at = now() WHERE id = $1", [a.id]);
  }
  return { sent, removedTokens };
}

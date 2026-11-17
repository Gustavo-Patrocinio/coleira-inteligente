import { createVerify, generateKeyPairSync } from "node:crypto";
import { describe, expect, it } from "vitest";
import { FcmSender, alertPushText } from "../src/push.js";

const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const sa = {
  project_id: "collar-test",
  client_email: "push@collar-test.iam.gserviceaccount.com",
  private_key: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
};

function fakeFcm(sendStatus: number) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchFn = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    if (url.includes("oauth2")) return new Response(JSON.stringify({ access_token: "at1", expires_in: 3600 }));
    return new Response("{}", { status: sendStatus });
  }) as unknown as typeof fetch;
  return { calls, fetchFn };
}

describe("FCM sender", () => {
  it("signs a service-account JWT, caches the access token and sends the message", async () => {
    const { calls, fetchFn } = fakeFcm(200);
    let t = 1_800_000_000_000;
    const fcm = new FcmSender(sa, fetchFn, () => t);
    expect(await fcm.send("tok-a", { title: "Thor scratched more than usual", body: "x", data: { alert_id: "1" } })).toBe("ok");
    t += 10 * 60_000;
    expect(await fcm.send("tok-b", { title: "t", body: "b" })).toBe("ok");
    expect(calls.map((c) => c.url.includes("oauth2"))).toEqual([true, false, false]); // one auth for both

    const assertion = new URLSearchParams(calls[0]!.init.body as URLSearchParams).get("assertion")!;
    const [h, p, sig] = assertion.split(".") as [string, string, string];
    expect(createVerify("RSA-SHA256").update(`${h}.${p}`).verify(publicKey, Buffer.from(sig, "base64url"))).toBe(true);
    const claims = JSON.parse(Buffer.from(p, "base64url").toString());
    expect(claims).toMatchObject({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging" });

    const send = calls[1]!;
    expect(send.url).toBe("https://fcm.googleapis.com/v1/projects/collar-test/messages:send");
    expect((send.init.headers as Record<string, string>).authorization).toBe("Bearer at1");
    expect(JSON.parse(send.init.body as string)).toEqual({
      message: { token: "tok-a", notification: { title: "Thor scratched more than usual", body: "x" }, data: { alert_id: "1" } },
    });
  });

  it("reports dead tokens so they can be deleted", async () => {
    expect(await new FcmSender(sa, fakeFcm(404).fetchFn).send("gone", { title: "t", body: "b" })).toBe("unregistered");
    expect(await new FcmSender(sa, fakeFcm(503).fetchFn).send("tok", { title: "t", body: "b" })).toBe("error");
  });
});

it("lock-screen text has no numbers and no medical claim", () => {
  expect(alertPushText("activity", "low", "Thor").title).toBe("Thor was less active than usual");
  expect(alertPushText("night_wakeups", "high", "Mel").title).toBe("Mel had a restless night");
  for (const m of ["activity", "scratching", "night_wakeups"]) {
    const { title, body } = alertPushText(m, "high", "Thor");
    expect(`${title} ${body}`).not.toMatch(/\d|diagnos|disease|sick/i);
  }
});

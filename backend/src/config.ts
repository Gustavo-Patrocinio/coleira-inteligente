import { z } from "zod";

const schema = z.object({
  DATABASE_URL: z.string().url().default("postgres://collar:collar@localhost:54329/collar"),
  JWT_SECRET: z.string().min(16, "JWT_SECRET must be at least 16 characters"),
  // 127.0.0.1 = only this machine (behind a reverse proxy on the same host)
  HOST: z.string().min(1).default("0.0.0.0"),
  PORT: z.coerce.number().int().default(3000),
  ALERTS_EVERY_MIN: z.coerce.number().int().min(0).default(60),
  // Firebase service account JSON (backend/DEPLOY.md, Push); unset = no push notifications
  FCM_SERVICE_ACCOUNT_FILE: z.string().optional(),
  // outgoing email for password reset codes (DEPLOY.md, Email); unset = no reset by email
  SMTP_URL: z.string().optional(),
  MAIL_FROM: z.string().optional(),
  // "true" behind a reverse proxy (deploy/docker-compose.yml sets it)
  TRUST_PROXY: z.enum(["true", "false"]).default("false").transform((v) => v === "true"),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return schema.parse(env);
}

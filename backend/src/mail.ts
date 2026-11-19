/**
 * Outgoing email (password reset codes). Any SMTP provider works: set SMTP_URL, e.g.
 * smtps://user:password@smtp.example.com:465, and MAIL_FROM. Without SMTP_URL the server
 * cannot send email and the reset endpoints answer 501 (DEPLOY.md, Email).
 */
import nodemailer from "nodemailer";

export interface MailMessage {
  to: string;
  subject: string;
  text: string;
}

export interface Mailer {
  send(msg: MailMessage): Promise<void>;
}

export class SmtpMailer implements Mailer {
  private readonly transport;

  constructor(
    url: string,
    private readonly from: string,
  ) {
    this.transport = nodemailer.createTransport(url);
  }

  async send(msg: MailMessage): Promise<void> {
    await this.transport.sendMail({ from: this.from, to: msg.to, subject: msg.subject, text: msg.text });
  }
}

/** The reset email: the code, how long it lasts, and what to do if it was not you. */
export function resetEmail(to: string, code: string): MailMessage {
  return {
    to,
    subject: `Your Smart Collar code: ${code}`,
    text: [
      `Your code to choose a new password is ${code}.`,
      "",
      "Type it in the app within 15 minutes. If you did not ask for it, ignore this email:",
      "your password stays the same.",
    ].join("\n"),
  };
}

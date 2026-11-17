# Privacy policy

> **Template for whoever runs a server.** This project is open: anyone can run their own
> server (`backend/DEPLOY.md`). The person or group that runs the server you sign in to is
> the **operator** and the data controller under Brazil's LGPD (Lei 13.709/2018). Fill in the
> fields in `[brackets]` and publish this page where your users can read it before signing up.
> It describes what the code in this repository actually does; if you change the code,
> update the policy. This is not legal advice.

**Operator:** [name] · **Contact for privacy requests:** [email] · **Version:** 1
(matches consent version 1 in the app) · **Last updated:** [date]

## In short

- The collar records **how your dog moved**, minute by minute. No location, no sound, no
  video, no photos.
- The data goes to the operator's server so the app can show your dog's routine and warn you
  when something changes. It is **not** a medical diagnosis.
- You can **download everything** or **delete your account and all its data** at any time,
  from the app (Collar tab → Your data).
- No advertising, no data sales, no analytics trackers.

## What is collected

| Data | Where it comes from | Why |
|---|---|---|
| Email and password (stored only as a one-way hash, scrypt) | you, at sign-up | your account and sign-in |
| Your dog's name, time zone, and optionally birth date and weight | you | show days and nights in your dog's local time; profile |
| The collar's Bluetooth address and a device key (stored only as a hash) | the app, when you pair the collar | so the server accepts data only from your collar |
| Per-minute activity: seconds still, walking, running, scratching, shaking, eating, drinking; battery level | the collar, through the app or the home base station | your dog's routine, trends and alerts |
| Daily summaries, alerts and your "made sense / false alarm" answers | computed by the server; your answers | alerts, and improving them |
| Your consent: which version you accepted, when, and whether you opted in to research | you, on the first screen | proof of consent (LGPD art. 8) |

The server also keeps standard technical logs (IP address, time, request path) for up to
[30] days, for security and to fix errors.

**Not collected:** location (GPS is not in the collar), microphone or camera data, contacts,
other apps. The app asks for Bluetooth permission to talk to the collar, and for camera and
microphone only in "Help improve recognition".

## Videos and raw recordings ("Help improve recognition")

Recording sessions are optional. The video and the raw motion file **stay on your phone**.
They leave it only if you share them yourself (for example, sending them to the project to
train the model). If you opted in to research, the operator may ask you for sessions; you
always choose what to send, and you can withdraw the opt-in in the app.

## Legal basis and purpose

Your **consent** (LGPD art. 7, I), given on the first screen of the app and recorded with its
version. The data is used only to:

1. show your dog's daily routine, trends and sleep estimated from movement;
2. learn what is normal for your dog and send alerts when it changes;
3. if you opted in, improve the recognition model with sessions you choose to share.

The app never claims a diagnosis. Alerts are suggestions to pay attention and, when in doubt,
talk to a veterinarian.

## Where the data is stored and who sees it

- On the operator's server at [hosting provider, country]. If the server is outside Brazil,
  the transfer relies on [legal basis, LGPD art. 33].
- The last 14 days of minutes are also kept on your phone so the app works offline.
- Nobody else sees your data. The operator does not share it, except when required by law.
- Connections use HTTPS. Passwords and device keys are stored only as hashes.
- When the app checks for collar updates, it asks GitHub (github.com, where the firmware is
  published) for the newest release; GitHub sees your IP address, as with any website.

## How long it is kept

- While your account exists.
- When you delete your account, everything is removed from the database **immediately**.
  Nightly backups on the server still hold a copy for up to **14 days**, then they are deleted
  too (backups are only used to recover from a server failure).
- Data on your phone is removed when you sign out or uninstall the app.

## Your rights (LGPD art. 18)

| Right | How |
|---|---|
| Access and portability | Collar tab → Your data → **Download my data** (a JSON file with everything the server has about you) |
| Correction | edit your dog's profile in the app, or write to [email] |
| Deletion | Collar tab → Your data → **Delete account and all data** |
| Withdraw consent | delete the account; for the research opt-in alone, change it in the app or write to [email] |
| Information and complaints | write to [email]; you can also contact the ANPD (gov.br/anpd) |

We answer requests within 15 days.

## Children

The app is meant for adults who own or care for a dog. Do not create an account for someone
under 18 without a parent or guardian.

## Changes

If this policy changes in a way that affects what is collected or how it is used, the app
asks for consent again (the consent version goes up) before any new use.

# thewonderworker.ca — read me first (CLAUDE.md)

This repository is the **public website** of the Nativity Celebration 2027 (Wonder Worker Art Team, St. Mina Coptic
Orthodox Church, Calgary), served by GitHub Pages at https://thewonderworker.ca (custom domain in `CNAME`).
It is **generated output**. The source is the sibling repository `drtamerwagdy-arch/nativity-2027-tickets`; its
`CLAUDE.md` and `WORKSPACE.md` describe the whole system and how the three repositories fit together.

## Do not edit the generated pages here

`./publish.sh` in nativity-2027-tickets rebuilds them from `web/src/` and overwrites whatever is here. To change
wording or design, edit the source there, look at it on its local demo (`node demo/server.js`), and let Tamer run
`./publish.sh` on his Mac: it commits here as "Website update (vX.Y)" and pushes; GitHub shows it within about a
minute, and pages already open on buyers' phones compare themselves with `version.json` and swap to the new copy.

| Generated — never by hand | Written by (in nativity-2027-tickets) |
|---|---|
| `index.html`, `team.html`, `owner.html`, `ticket/index.html`, `donate/index.html`, `sponsor/index.html`, `nativity-2027.ics`, `sales-sheet.pdf` | `tools/site_pages.py` |
| `demo/`, `team-demo/`, `demo-assets/`, `team-help.html` | `demo-web/build_demos.py` |
| `favicon.ico`, `icon-*.png`, `apple-touch-icon.png`, `site.webmanifest` | `tools/build_icons.py` |
| `version.json` | `publish.sh` |

**Kept by hand, here:** `CNAME`, `privacy/index.html`, `robots.txt`, `sitemap.xml`, `share-card.png`, the Google
Search Console verification file (`google…html`), `README.md`, this file. A hand commit says what changed and why.

## What each page is

- `/` — the public page: Get tickets · Donate · Become a sponsor. Findable by search engines (Tamer 2026-10-04) and
  carrying a link preview (`share-card.png`) so a shared link shows the poster and the date.
- `/donate/`, `/sponsor/` — the same page opened on that tab; the QR codes on the TV, the banners and the posters point here.
- `/ticket/` — the "Save ticket" links from the tickets e-mail (noindex).
- `/team.html?k=…`, `/owner.html?k=…` — the team page and Tamer's dashboard. Hidden from search engines; each person's
  key is in their own link and nowhere in this repository.
- `/team-help.html` — the team guide. `/demo/`, `/team-demo/` — practice copies that run the whole engine inside the
  browser; nothing there is real or sent.
- `/privacy/` — the privacy policy (also the App Store privacy URL of the parish app, `stmina-app`).

## How it works

Static files only: no data, no keys, nothing to run, no build step and no CI in this repository. Every page POSTs
`{action, payload}` to the ticket engine (a Google Apps Script web app owned by artteam@stminacalgary.ca; its address
is baked into the pages from `.deployment-id` in the source repository). GitHub Pages serves the root of `main`.

## In a Claude Code session

- Fine here: reading the live pages, checking links and wording, editing the hand-kept statics above.
- Not here: any change to a generated page. Make it in `nativity-2027-tickets/web/src/` and say so.
- When this repository is checked out next to `nativity-2027-tickets`, its `setup-workspace.sh` links it there as
  `github-pages/`, so `python3 tools/site_pages.py` and `python3 demo-web/build_demos.py --no-render` write into this
  clone; `git status` here then shows exactly what a publish would change. Leave the publishing itself to Tamer.
- The wording rules apply to everything on the site: a church service, admission by donation ("suggested $20 or
  more"), never "purchase"; plain words; Calgary time. Decisions are logged in `nativity-2027-tickets/EDITS.md`.

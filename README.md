# Voices — hold-to-talk Thai dictation for Mac

Hold a key, speak Thai mixed with English, let go — the text lands in whatever field you were typing in.
Speech is transcribed **on your Mac** by a local model; audio never leaves the machine.

กดปุ่มค้าง พูดไทยปนอังกฤษ ปล่อยปุ่ม แล้วข้อความจะไปอยู่ในช่องพิมพ์ที่เลือกไว้ ถอดเสียงบน Mac ด้วยโมเดลในเครื่อง เสียงไม่ออกจากเครื่อง

This is the open-source code behind **Pink voices** by pngoung. The official app with its name, icon and artwork
is a free gift at <https://nongkao.tkd-crm.com/pink-voices>; this repository builds a plain, unbranded app you can
study, change and ship under your own name (see [TRADEMARKS.md](TRADEMARKS.md)).

## What it does

- **Hold to talk** — Right Option by default (F7/F8 also available). A click-through animated capsule shows the
  voice level while listening and what happens next.
- **Local AI** — iApp's OpenThai 2.0 ASR streaming model runs in a small local service on 127.0.0.1.
  First launch offers a one-time setup (~4 GB download) into `~/Library/Application Support/<App>/LocalAI`.
- **Works in any app** — inserts into the focused editable field through Accessibility; optional ⌘V paste mode.
- **Your words** — teach "heard → written" pairs. Tick *brand or person's name* and spellings that *sound alike*
  are caught too (Thai sound keys ignore tone marks, silent letters and same-sound consonants).
- **Quick fix** — highlight a wrong word in any app, tap Control + Option, type the right spelling, Enter.
- **Optional AI word check** — Sign in with ChatGPT (the user's own ChatGPT plan) or the user's own OpenAI API
  key. Only the transcribed text is sent, never audio. Off by default.
- **Stops early on silence** — if nothing was heard, it gives up 3 s after release.

## Build

Requirements: Apple silicon Mac, macOS 13+, Xcode Command Line Tools.

```bash
./App/build.sh                      # ad-hoc or "Apple Development" signing → App/build/Voices.app
./scripts/check-core.sh             # Swift checks + Python tests (needs ASR/.venv, see below)
```

Developer setup of the speech service (the app's installer does the same for end users):

```bash
cd ASR && ./setup.sh && ./start.sh   # needs `uv` on PATH; downloads the model from Hugging Face
```

Set your own name and bundle identifier in `App/Info.plist` (`CFBundleDisplayName`, `CFBundleIdentifier`) and
replace `App/Resources/AppIcon.png`. Optional keys: `PVCredit` (footer credit), `PVSourceURL`, `PVFamily`
(cards linking to your other apps).

## Privacy

- Audio is processed only by the local service on 127.0.0.1.
- The optional online word check sends the transcribed text and the matching taught words to OpenAI.
- API keys and the ChatGPT sign-in are kept in the macOS Keychain.

## Licences

- Code: Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
- Speech model (downloaded, not included): OpenThai 2.0 ASR by iApp, OpenMDW-1.1 — see
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- "Pink voices", its icon, mascots and artwork are not covered by the code licence — see [TRADEMARKS.md](TRADEMARKS.md).

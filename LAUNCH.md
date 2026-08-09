# Launch kit — EcoFlowBar

Ready-to-paste copy for launching. Links:
- Repo: https://github.com/matguig/ecoflowbar
- Site: https://matguig.github.io/ecoflowbar
- Latest DMG: https://github.com/matguig/ecoflowbar/releases/latest

> Tip: attach the demo GIF to every post. Tone matters — lead with the
> problem you had, not with "my app". Post mid-week, morning US time.

---

## Hacker News — Show HN

**Title** (≤ 80 chars, no emoji, HN hates hype):

```
Show HN: EcoFlowBar – Your EcoFlow battery in the Mac menu bar
```

**URL field:** https://github.com/matguig/ecoflowbar

**First comment** (post it right after submitting):

```
I run a Mac mini M4 off an EcoFlow River 3 Plus (van desk + outage-proof
home office). A desktop Mac has no battery, so macOS shows nothing — no
percentage, no time remaining, no low-power reflexes. I wanted the
MacBook experience back.

EcoFlowBar talks to the battery directly over Bluetooth LE (no cloud,
works fully offline) using the reverse-engineered EF protocol from the
ha-ef-ble project. It shows real time-remaining in the menu bar and adds
laptop-style protection: notify → low-power mode (pmset) → clean shutdown
that saves your session and restores it at next login. It can also write
charge/discharge limits to the battery (80–85% daily keeps LFP cells
healthy), and everything is computed on the *effective* usable window.

Some things I enjoyed building:
- A Dia-style full-screen onboarding, all native SwiftUI (no videos).
- The daemon is a supervised child process of the app: it lives and dies
  with the app, and on a crash it detects EOF on stdin and stops itself.
- Distribution is a notarized DMG via GitHub Actions on tag push. The fun
  bug: notarization kept returning "Invalid" until I signed the ~200
  embedded Python binaries inside-out (hardened runtime + timestamp each)
  instead of relying on --deep.

Free, open source (app is MIT-ish; the BLE library is Apache-2.0 and
vendored with its license). Not affiliated with EcoFlow. Feedback welcome
— especially from anyone with a different EF model to test.
```

---

## Product Hunt

**Name:** EcoFlowBar

**Tagline** (≤ 60 chars):

```
Your EcoFlow battery in the Mac menu bar
```

**Description:**

```
A Mac mini has no battery — plug it into an EcoFlow power station and
macOS still shows nothing. EcoFlowBar gives your Mac its battery
indicator back: real time remaining in the menu bar, 100% local over
Bluetooth (no cloud, works offline), plus laptop-style protection —
low-power mode and a clean shutdown that saves and restores your session
before the battery dies. Battery-health charge limits, a 24h history
chart, six languages. Free and open source.
```

**Maker's first comment:**

```
Hi PH! I built this to scratch my own itch: a Mac mini M4 running off an
EcoFlow River 3 Plus, with no way to see how much runtime I had left.
It's 100% local (Bluetooth LE straight to the battery), notarized, and
open source. The onboarding is a little love letter to Dia's intro.
Happy to answer anything — and keen to hear which EcoFlow models you'd
want supported next.
```

**Topics:** Mac, Menu Bar, Open Source, Productivity

---

## Reddit

### r/EcoFlow  (also works for r/vandwellers, r/GoRVing, r/solar)

**Title:**

```
I made a free menu-bar app so my Mac mini shows my River 3 Plus's real runtime
```

**Body:**

```
I run a Mac mini off a River 3 Plus and it always bugged me that macOS
had no idea it was on a battery — no percentage, no time remaining. So I
built EcoFlowBar: it reads the battery directly over Bluetooth (no cloud,
works fully offline) and shows real time-remaining right next to the
clock, like a laptop.

It also protects the Mac automatically when the battery gets low
(low-power mode, then a clean shutdown that reopens everything at next
boot), and it can set charge limits to keep the cells healthy.

It's free and open source. Works on Apple Silicon Macs, macOS 14+.
Tested on the River 3 Plus; other EF models should work too and I'd love
reports. Download + source: https://github.com/matguig/ecoflowbar

(Not affiliated with EcoFlow — just a happy user.)
```

### r/macapps  (also r/macmini, r/MacOS)

**Title:**

```
[Free/Open Source] EcoFlowBar — give your Mac mini a battery indicator when it runs off an EcoFlow
```

**Body:**

```
If you run a Mac (mini, Studio…) off an EcoFlow portable power station,
macOS shows nothing about the battery. EcoFlowBar puts the % and real
time-remaining in your menu bar, talking to the battery over Bluetooth LE
— fully local, no cloud, no account polling.

Bonus: it acts like a smart UPS (notify → low-power mode → clean shutdown
with session restore) and can write charge limits for battery health.
Native SwiftUI, notarized DMG, six languages, and a genuinely nice
onboarding.

Free + open source: https://github.com/matguig/ecoflowbar
Site with a demo: https://matguig.github.io/ecoflowbar
```

> On r/macapps, flair the post `[Free]` and disclose it's your own app —
> that sub requires it and rewards honesty.

---

## awesome-mac contribution

Repo: https://github.com/jaywcjlove/awesome-mac
Section: **Utilities → Menu Bar Tools** (alphabetical order).

Entry line to add:

```
* [EcoFlowBar](https://github.com/matguig/ecoflowbar) - Shows your EcoFlow power-station battery (level, real time remaining) in the menu bar over Bluetooth, with laptop-style protection. [![Open-Source Software][OSS Icon]](https://github.com/matguig/ecoflowbar) ![Freeware][Freeware Icon]
```

Steps: fork → add the line in the Menu Bar Tools list (keep alphabetical)
→ PR titled `Add EcoFlowBar (menu bar EcoFlow battery indicator)`.
Read their CONTRIBUTING first; they require the badges above and a
neutral, non-marketing description.

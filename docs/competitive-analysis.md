# Competitive Analysis: Line-Learning / Script-Rehearsal Apps for Actors

_Prepared for CastCircle — June 2026. CastCircle helps actors learn lines and rehearse scripts: import a script, the app reads the other characters' lines aloud, listens to the actor say their line and auto-advances, and lets a cast share recordings._

All figures below were pulled from App Store / Google Play listings, developer sites, and third-party review/estimate sites in June 2026. Store ratings counts and Google Play install buckets are the best available download proxies; where a number is an estimate or could not be confirmed, it is flagged. Prices are USD.

---

## 1. Executive Summary

**Market leaders (by popularity signal):**

- **coldRead** is the clear critical and popularity leader on iOS. The established listing carries **~3,700 ratings at 4.4 stars** — by far the largest review base of any rehearsal-specific app — and it was ranked #1 by Backstage. It pioneered the exact "listen for your last word, auto-advance, 100% on-device" interaction CastCircle is built around. (Note: there are multiple coldRead-branded listings; see per-app notes.)
- **Script Rehearser** is the **Android volume leader**: **100K+ installs**, ~1,900–2,070 ratings at ~4.05 stars, free, and still actively updated (March 2026). It is cross-platform (iOS + Android) and one of the oldest apps in the category (since 2014).
- **Run Lines With Me** is a strong iOS mid-tier player: **1,300+ ratings at 4.7 stars** with an unusually cheap subscription (as low as $4.99/year).
- **Rehearsal Pro** is the legacy "professional actor" incumbent (NYT/Backstage press, claims 1.2M+ scripts rehearsed) but has a modest and somewhat soft store footprint (**66 ratings, 3.6 stars**) and a premium one-time price.
- **LineLearner** is a long-running cross-platform budget option, strong on iOS (**135 ratings, 4.3 stars**) but weaker on Android (~10K+ installs, ~2.8–2.9 stars).
- A **wave of new AI apps (2024–2026)** — ScenePartner, ActingPal, Off Book/Offbook, Rafy, Rehearser, Slatable, RehearseNow.ai, Linus, Run Lines: Script Rehearsal — are entering fast, mostly on **subscription** models, but most have **tiny review counts so far** (single digits to a few hundred), meaning the AI segment is still wide open.

**Prevailing pricing:**

- **One-time purchase** (the older "record/playback" generation): **$3.99–$19.99** (LineLearner ~$4–5; Rehearsal Pro $19.99).
- **Subscription** (the new AI/scene-partner generation): roughly **$5–$20/month** and **$50–$200/year**, with a cluster around **~$7–$10/month** and **~$50–$100/year**. Outliers exist at both ends — Run Lines With Me at $4.99/year (extraordinarily cheap) and ScenePartner Pro at $44.99/month / $459.99/year (extraordinarily expensive).
- **Free tiers are now the norm** for new apps, gated by script count (coldRead: ≤8 lines/scene free; ScenePartner/Offbook-style: ~3 free scripts) or recording count (Run Lines With Me: 10 recordings).

**Takeaways for CastCircle pricing/positioning:**

1. **The market has bifurcated**: cheap one-time legacy apps vs. recurring AI-subscription newcomers. CastCircle's on-device AI stack (OCR import + on-device TTS + speech-recognition auto-advance) is firmly in the *premium AI* category, which justifies a subscription — but the credible willing-to-pay band is **~$6–$10/month or ~$50–$80/year**, not the $20+/month that ScenePartner is testing.
2. **A free tier gated by a usage limit is now table stakes.** Gate on script count (most common) and keep the auto-advance "magic" available in free to drive conversion.
3. **On-device is a real, defensible wedge.** Only coldRead aggressively markets "100% on-device, no account, no internet." Most of the new AI crop (Offbook, RehearseNow, Linus, Rafy) rely on **cloud voices (ElevenLabs etc.)**, which means privacy concerns, latency, and per-use cost. CastCircle's fully on-device pipeline can undercut their pricing while matching the "it responds to my cue" experience — and **cast recording-sharing is under-served** across the board.

---

## 2. Comparison Table

| App | Platforms | Ratings (count / avg) | Est. downloads / popularity | Pricing | Key features | Maintained? |
|---|---|---|---|---|---|---|
| **coldRead** (id1264354117) | iOS (iPhone/iPad/M-Mac/Watch) | ~3,700 / 4.4★ | Largest review base in category | Free ≤8 lines; sub $6.99–$10.99/mo (annual $83.99); 1-wk trial | On-device speech recog auto-advance, teleprompter, self-tape 4K, scene sharing, offline | Yes (active brand; see note on listings) |
| **Cold Read: Actor Rehearsal** (id6759092894) | iOS (iPhone/iPad/M-Mac) | Too few to display | New (2025) | Free; $9.99/mo or $79.99/yr | Smart cue recognition, on-device, teleprompter, 10+ languages | Yes (Mar 2025) |
| **Script Rehearser** | iOS + **Android** | ~1,900–2,070 / ~4.05★ (Play) | **100K+ installs (Play)**; since 2014 | Free base; ~$10–$30 tier reported (synthesized voices + import) | TTS + own-voice recording, import/type scripts, Listen Along / Wait For Me / Repeat modes | Yes (Mar 2026) |
| **Run Lines With Me** | iOS | 1,300+ / 4.7★ | Strong iOS mid-tier | Free (10 recs/150 min); $1.99/3mo, $3.99/6mo, **$4.99/yr** | Record once, auto-gap playback, speed control, BT/background | Yes (Apr 2025) |
| **Rehearsal Pro** | iOS (iPhone/iPad) | 66 / 3.6★ | Legacy incumbent; claims 1.2M+ scripts rehearsed; NYT/Backstage press | **$19.99 one-time** | Highlight/blackout, record + teleprompter scroll, beat marks, Car Mode, PDF/Word + scan, MP3 export, cross-device sync | Yes (Oct 2025) |
| **LineLearner** | iOS + Android | iOS 135 / 4.3★; Android ~304 / ~2.8★ | Android ~10K+ installs | **$3.99–$5.49 one-time** | Record scene, gap-out your part, pitch-shift others, PDF/Word import, **share recordings with cast** | iOS Jul 2024; Android older |
| **ScenePartner: AI Line Reader** | iOS | 6 / 5.0★ (very new) | New (2024–25); claims 10,000+ actors | Free 3 scripts; Plus $19.99/mo or $199.99/yr; **Pro $44.99/mo or $459.99/yr** | AI voice read, speech recog follow, import sides, teleprompter, in-app self-tape | Yes (2025, very active) |
| **ActingPal: AI Scene Partner** | iOS | 7 / 1.9★ | New; quality complaints | Free; Pro $9.99/mo (promo $8.99) | AI voices, **on-device text extraction**, responsive cueing, self-tape, scene sharing, letter-reveal | Yes (Apr 2025) but buggy |
| **Off Book / Offbook (offbook.co)** | Web (app.offbook.co); mobile unclear | n/a (web) | "Actors from Juilliard, Yale, NYU, LAMDA, RADA, RSC" | Freemium (pricing page gated) | AI scene partner (ElevenLabs voices), PDF/image import, "Genie" subtext assistant, self-tape | Yes |
| **Off Book!** (id921046788, Lugovsky) | iOS | 38 / 4.1★ | Old | Free; LineSync IAP $1.99/mo | Record by Work/Scene/Char/Line, mute/cue my line, LineSync sharing | **No (last update 2017)** |
| **Rafy – Self-Tape Acting Reader** | iOS, Android, Web | individual 5★ reviews; overall n/a | New-ish | $9.99 / $14.99 / $24.99 mo (token-based); $1.99/3-day pass | Reader voice by gender/age/accent/mood; **real actor voices (paid per use)**; self-tape | Yes |
| **Rehearser (rehearser.co)** | iOS | n/a | "thousands of working actors" (claim) | Free (2 scenes) + Industry Pro sub | 20+ voices, emotional cueing/intonation control, document scanning, teleprompter | Yes |
| **Slatable** | iOS | 674 reviews | Since 2016 | Free; Basic $4.99/mo ($50.90/yr); **Premium $9.99/mo ($95.90/yr)** | Self-tape first; **ScenePartner AI voice-changer** (record + revoice partner lines); teleprompter | Yes |
| **RehearseNow.ai** | Web (all devices) | G2-listed | Marketed to "pro actors" | $15/mo or **$100/yr** (~$8.33/mo); 7-day trial | Cloud AI voices, cross-device sync, self-tape, no app-store download | Yes |
| **Linus** | iOS, Android, Web | n/a (new) | New 2026 | Free; **$9.99/mo unlimited**; 3-day passes from $1.99 | AI scene partner w/ **speech-recog auto-advance**, self-tape + teleprompter, table read, real (paid) voice actors, cross-platform sync | Yes |
| **Run Lines: Script Rehearsal** (Sebastin Michael) | iOS | 2 / 3.0★ | New (2025) | Free; $3.99/wk, $5.99/mo, **$49.99/yr** | **Offline AI voices** per character, Listen Along / Wait For Me, PDF import, recording, analytics | Yes (Apr 2025) |
| **ActOnCue** | Web, iOS | n/a | Web-first | **Pay-as-you-go: $20 min top-up** (~55 hrs rehearsal) | Auto character detection, **cloud speech recognition**, progressive text-hiding mnemonics, cross-platform sync | Yes |

---

## 3. Per-App Notes (Top ~10)

### coldRead — the app to beat (and CastCircle's closest analog)
- Developer: Miljan Milosevic (established listing id1264354117); a separate "Cold Read: Actor Rehearsal" (id6759092894) is published by Meta Innovation Limited, and a third "Cue" coldread-style brand exists. The branding is fragmented, but the established listing's **~3,700 ratings / 4.4★** is the single biggest social-proof asset in the category.
- Does exactly what CastCircle does: **on-device speech recognition detects when you finish your line and auto-triggers the next cue** with "realistic timing variability." Plus teleprompter, 4K self-tape, scene sharing.
- Pricing: free for scenes **under 8 lines** (covers many co-star auditions), then $10.99/mo, $8.99/mo (3-mo), **$6.99/mo (annual)**. Annual IAP listed as $83.99.
- Heavily markets **"100% on-device, no account, no cloud, no internet."** This is the positioning CastCircle most directly competes with — and the one most apps cannot match.
- Source: App Store id1264354117; coldreadapp.com.

### Script Rehearser — the Android/cross-platform volume leader
- Cross-platform (iOS + Android), live since 2014, still updated **March 2026**. **100K+ Google Play installs**, ~1,900–2,070 ratings at **~4.05★** — the strongest *download-proxy* of any cross-platform competitor.
- Free to download; offers **built-in synthesized voices OR your own recordings**, type/import scripts, and three rehearsal modes (Listen Along / Wait For Me / Repeat for Confirmation). A paid tier (~$10–$30 reported in roundups) unlocks more.
- The closest "mass market, both stores, free entry" competitor; weaker on modern AI voices and auto-advance polish.
- Source: scriptrehearser.com; Play store com.rehearser.rehearser3free; Similarweb/AppBrain.

### Run Lines With Me — cheap subscription, high satisfaction
- iOS only, developer Nonzero Solutions. **1,300+ ratings at 4.7★** — the highest rating among high-volume apps.
- Record the scene once, mark your lines, playback leaves gaps; speed control, background/Bluetooth.
- **Aggressively cheap**: free (10 recordings / 150 min), then $1.99/3mo, $3.99/6mo, **$4.99/year**. Reviewers explicitly praise it for being affordable vs. competitors.
- Lacks AI voices / OCR import / speech-recognition auto-advance — it's the polished *budget recording* app. Sets a low price anchor actors notice.
- Source: App Store id1269241182.

### Rehearsal Pro — the legacy "professional" premium incumbent
- Developer Sotto Voce Filmworks. Marketed as "#1 best-selling app for professional actors," NYT/Backstage press, claims **1.2M+ cumulative scripts rehearsed**.
- **$19.99 one-time, no IAP** — the high end of one-time pricing and the de-facto ceiling for "buy once."
- Deep feature set: highlight/blackout, record + teleprompter-scroll playback, beat marks, annotations, Car Mode, PDF/Word + Adobe scan, MP3 export, cross-device sync.
- But store footprint is modest/soft: **66 ratings at 3.6★** (bugs cited in reviews). Strong brand, aging UX.
- Source: App Store id1116896197; rehearsal.pro.

### LineLearner — long-running budget cross-platform
- Developer Peter Allday. iOS **135 ratings / 4.3★**; Android weaker (~**10K+ installs, ~2.8–2.9★, ~304 ratings**).
- **One-time $3.99 (iOS) / ~$5.49 (Android)**, no subscription, no ads — a deliberate value play.
- Record scene, gap-out your part, pitch-shift other characters, PDF/Word import, and notably **share recordings with scene partners** (cast collaboration — directly relevant to CastCircle's sharing feature).
- iOS last updated Jul 2024; Android lagging. Beloved but dated.
- Source: App Store id368070258; Play com.alldayapps.android.linelearner.

### ScenePartner: AI Line Reader — the premium-priced AI newcomer
- Developer Gumball LLC. Very new (v1.2, 2024–25), only **6 ratings (5.0★)** so far; claims 10,000+ actors.
- Free for **3 scripts**, then the most expensive tiers in the market: **Plus $19.99/mo or $199.99/yr; Pro $44.99/mo or $459.99/yr.**
- AI voice reads partner lines, speech recognition follows you, import sides, teleprompter (XL text / high contrast), in-app self-tape.
- Tests whether actors will pay near-prosumer SaaS prices. CastCircle can credibly position as "the same auto-advance experience, on-device, at a fraction of the price."
- Source: App Store id6737419907.

### ActingPal: AI Scene Partner — AI features, execution problems
- Developer Acting Pal Ltd. **7 ratings at 1.9★** — quality/stability complaints (failed playback, unstable self-tape, slow support).
- Free; Pro **$9.99/mo (promo $8.99)**.
- Notable that it markets **on-device text extraction** for privacy, AI voices, responsive cueing, scene sharing, letter-reveal memorization. A cautionary tale: AI ambitions undercut by execution — an opening for a polished on-device app.
- Source: App Store id6736730265.

### Off Book / Offbook (offbook.co) — the prestige web AI tool
- Web app (app.offbook.co); mobile availability unclear. Markets "actors from Juilliard, Yale, NYU, LAMDA, RADA, RSC."
- AI scene partner **powered by ElevenLabs** (cloud TTS), PDF/image import, a "Genie" subtext/motivation assistant, synced self-tape cues. Freemium (pricing page gated).
- Strong brand/prestige positioning; cloud-dependent (privacy + latency + per-use cost are weaknesses CastCircle can exploit). Distinct from the abandoned **Off Book!** iOS app (id921046788, last updated 2017).
- Source: offbook.co.

### Slatable — self-tape app that bolted on an AI scene partner
- iOS, since 2016, **674 reviews**. Primarily a self-tape/audition tool, now with a **ScenePartner AI voice-changer** (record partner lines, revoice them naturally).
- Clear tiering: Free (1 audition/mo), **Basic $4.99/mo ($50.90/yr)**, **Premium $9.99/mo ($95.90/yr)**; AI voice currently bundled free into Premium (limited time, 2-hr monthly reset).
- Demonstrates the **$5 / $10 per-month, ~$50 / ~$95 per-year** sweet spot the market is converging on.
- Source: App Store id1080031696; slatable.com/priceplans.html.

### RehearseNow.ai & Linus — cloud AI scene partners, ~$8–15/mo
- **RehearseNow.ai**: web, cloud AI voices, cross-device sync, self-tape. **$15/mo or $100/yr (~$8.33/mo)**, 7-day trial.
- **Linus**: iOS/Android/web, AI scene partner with **speech-recognition auto-advance**, self-tape + teleprompter, table read, real (paid) voice actors, unified cross-platform sync. Free; **$9.99/mo unlimited**; 3-day passes from $1.99.
- Both validate **~$8–$15/mo / ~$100/yr** as the standard AI subscription, and both are **cloud-based** — i.e., directly beatable by an on-device offering on privacy/offline/cost.
- Sources: rehearsenow.ai; getlinus.app.

---

## 4. Pricing Analysis

**One-time purchase (legacy "record & play back" generation):**
- Range: **$3.99 – $19.99.**
- LineLearner anchors the low end ($3.99–$5.49); Rehearsal Pro anchors the high/ceiling end ($19.99). This model is fading for new entrants (no recurring revenue, hard to fund AI voice costs), but it sets actors' price expectations and a strong "$20 buys it forever" reference point.

**Subscription (modern AI / scene-partner generation):**
- **Monthly:** broad range **$3.99 – $44.99**, but the realistic cluster is **~$6.99 – $10.99/mo** (coldRead $6.99–$10.99; ActingPal/Linus/Slatable Premium/Cold Read $9.99; RehearseNow $15). ScenePartner ($19.99 / $44.99) is an outlier high; Run Lines: Script Rehearsal ($5.99) and weekly micro-prices sit low.
- **Annual:** realistic cluster **~$49.99 – $99.99/yr** (Run Lines: Script Rehearsal $49.99; Slatable Premium $95.90; Cold Read $79.99; coldRead $83.99; RehearseNow $100). Outliers: Run Lines With Me **$4.99/yr** (rock bottom) and ScenePartner **$199.99–$459.99/yr** (top).
- Annual plans typically discount **~20–44%** vs. monthly — standard.

**Free-tier norms (almost universal for new apps):**
- Gate by **script/scene count** (most common): coldRead ≤8 lines/scene; ScenePartner/Offbook-style ~3 scripts; Slatable 1 audition/mo.
- Gate by **recording count**: Run Lines With Me 10 recordings (150 min).
- Pay-as-you-go exists but is rare: ActOnCue ($20 ≈ 55 hrs); Rafy token system.
- The free tier almost always **includes the core "magic"** (the AI reads / auto-advances) so users feel the value before the paywall.

**Implication:** the defensible price window for a premium on-device AI app is roughly **$6.99–$9.99/month and $49.99–$79.99/year**, undercutting the cloud incumbents (RehearseNow $100/yr, ScenePartner $200+/yr) on the strength of zero cloud-voice cost — with a free tier of ~3 scripts (or an equivalent scene/line limit) to drive conversion.

---

## 5. Gaps & Positioning for CastCircle

**Where the market is weak / under-served:**

1. **On-device AI is rare and a genuine moat.** Only **coldRead** (and the newer "Cold Read") strongly market "100% on-device, no account, no internet." The fast-growing, well-funded-looking AI crop — **Offbook (ElevenLabs), RehearseNow, Linus, Rafy, ActOnCue** — is **cloud-dependent**. Cloud means privacy exposure (scripts under NDA leaving the device), latency in the cue response, network dependence on set/backstage, and per-use voice cost. **CastCircle's fully on-device OCR + TTS + speech-recognition stack is a real differentiator** that simultaneously (a) protects confidential scripts, (b) works offline anywhere, and (c) carries near-zero marginal cost — letting CastCircle price below the cloud players profitably. This is the single strongest wedge: *"coldRead-class on-device experience, but with OCR script import and cast sharing, at a fair price."*

2. **Cast recording-sharing is thin across the field.** Only **LineLearner** (share recordings), **coldRead** (scene/line share), **Slatable**, and **ActingPal** mention any collaboration, and it's secondary for all of them. None has built a *cast-centric* sharing workflow as a headline feature. CastCircle's "a cast shares recordings" is **the most differentiated part of its pitch** — most rivals are solo-actor tools. Lean into ensemble/production use (theatre companies, drama programs, recurring TV casts).

3. **OCR script import is uneven.** Several apps require manual entry or charge per import (older Scene Partner charged $1.99 per script). Rehearsal Pro scans via Adobe; Offbook/ActingPal do PDF/image. A **frictionless on-device OCR import** (PDF + photo of sides, auto character detection like ActOnCue/Blablabla) removes the biggest setup-pain point and should be free-tier, not gated.

4. **Auto-advance speech recognition is the "wow," and most legacy apps lack it.** Rehearsal Pro, LineLearner, Run Lines With Me, Script Rehearser, Off Book! are all **record-and-playback** with manual/gap timing — they do **not** listen and auto-advance. That capability is concentrated in the new AI cohort (coldRead, ScenePartner, Linus, ActingPal). CastCircle is correctly on the right side of this transition; it must match coldRead's reliability here because that's the feature actors rave about.

5. **Quality bar is beatable.** The newest AI apps with the most ambition often ship buggy (**ActingPal 1.9★**, **ScenePartner/Run Lines: Script Rehearsal** with single-digit ratings). The legacy leaders are stable but dated (**Rehearsal Pro 3.6★, aging UX; Off Book! abandoned since 2017; LineLearner Android 2.8★**). A polished, reliable, modern on-device app can win on execution alone.

**Suggested price point (data-driven):**
- **Subscription, freemium.** Free tier: ~3 scripts (or an equivalent scene/line cap) with the full on-device auto-advance experience and OCR import included so users feel the magic.
- **~$7.99–$9.99/month** and **~$59.99–$79.99/year** (annual discounted ~30–40%). This sits at the proven cluster, **undercuts the cloud incumbents** (RehearseNow $100/yr, ScenePartner $200+/yr) while being clearly premium vs. the budget one-time apps, and is justified by on-device AI + cast sharing.
- Consider an **ensemble/team plan** (per-production or seat-based) to monetize the cast-sharing feature — a lane essentially no competitor occupies.
- A **one-time "buy it forever"** option (~$29.99) could be offered as a hedge against the price-sensitive segment anchored by Rehearsal Pro's $19.99 and LineLearner's $4–5, but recurring is the better fit for ongoing on-device model/voice updates.

---

## Sources

- Rehearsal Pro — App Store: https://apps.apple.com/us/app/rehearsal-pro/id1116896197 ; https://rehearsal.pro/
- LineLearner — App Store: https://apps.apple.com/us/app/linelearner/id368070258 ; Google Play: https://play.google.com/store/apps/details?id=com.alldayapps.android.linelearner ; AppRecs (Android installs/rating): https://apprecs.com/android/com.alldayapps.android.linelearner/linelearner
- coldRead — App Store (established): https://apps.apple.com/us/app/coldread/id1264354117 ; site: https://www.coldreadapp.com/
- Cold Read: Actor Rehearsal — App Store: https://apps.apple.com/us/app/cold-read-actor-rehearsal/id6759092894
- Cue (cold read brand): https://cuecoldread.app/
- Script Rehearser — site: https://www.scriptrehearser.com/ ; Google Play: https://play.google.com/store/apps/details?id=com.rehearser.rehearser3free ; AppBrain: https://www.appbrain.com/app/script-rehearser/com.rehearser.rehearser3free ; Similarweb: https://www.similarweb.com/app/google-play/com.rehearser.rehearser3free/statistics/
- Run Lines With Me — App Store: https://apps.apple.com/us/app/run-lines-with-me/id1269241182 ; https://runlineswithme.com/
- Run Lines: Script Rehearsal — App Store: https://apps.apple.com/us/app/run-lines-script-rehearsal/id6755323192
- ScenePartner: AI Line Reader — App Store: https://apps.apple.com/us/app/scenepartner-ai-line-reader/id6737419907
- ActingPal: AI Scene Partner — App Store: https://apps.apple.com/us/app/actingpal-ai-scene-partner/id6736730265
- Off Book / Offbook — https://www.offbook.co/
- Off Book! (legacy iOS) — App Store: https://apps.apple.com/us/app/off-book/id921046788
- Rafy — App Store: https://apps.apple.com/us/app/rafy-self-tape-acting-reader/id6478787835
- Rehearser — https://rehearser.co (via Scriptation roundup)
- Slatable — App Store: https://apps.apple.com/us/app/slatable-audition-app/id1080031696 ; price plans: https://slatable.com/priceplans.html
- RehearseNow.ai — https://rehearsenow.ai/ ; review: https://www.futurepedia.io/tool/rehearsenow
- Linus — https://www.getlinus.app/blog/the-best-ai-tools-for-actors-in-2026
- ActOnCue — https://actoncue.com/ ; roundup: https://actoncue.com/blog/best-line-learning-apps
- Backstage roundup ("7 Line Memorization Apps"): https://www.backstage.com/magazine/article/line-memorization-apps-actors-70280/
- Scriptation roundup ("16 Best Apps for Actors in 2026"): https://scriptation.com/blog/best-apps-for-actors/
- Qonversion (LineLearner price intel): https://qonversion.io/apps/ios/linelearner/368070258
- Self-e-Tape (self-tape apps 2026): https://selfetape.com/blog/best-self-tape-apps-for-actors-2026

_Note on confidence: App Store rating counts/averages and Google Play install buckets are from live store listings (June 2026) and are reliable. Tiered subscription prices were read from store IAP listings and developer pricing pages. "Est. downloads," prestige/usage claims (e.g., "10,000+ actors," "1.2M+ scripts"), and a few paid-tier prices for cross-platform apps (Script Rehearser's paid tier) are vendor- or roundup-reported and should be treated as approximate. coldRead's listing landscape is fragmented across multiple bundle IDs/publishers; the ~3,700-rating figure refers to the established id1264354117 listing._

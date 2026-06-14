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
- **Loved (top positive review themes):**
  - Best-in-class line learning — "the best line learning tool I've ever used"; the hands-free cue-word trigger is the standout that earns the 4.4★/3,700-rating base.
  - Removes the need for a scene partner — actors repeatedly praise being able to rehearse and self-tape solo, "WHILE recording a video."
  - Generous free tier — "the best part, coldRead is free" (free for scenes under 8 lines covers many co-star auditions); built-in teleprompter is well liked.
- **Pain points (top negative review themes):**
  - Recording/audio glitches — reviewers report the self-tape audio "cuts some portions out" and that recorded lines sound "very edited"/unnatural; noise-cancellation is applied inconsistently to the reader vs. the actor's own voice.
  - Speech-recognition misses — the cue-word recognition sometimes fails to trigger the next line, forcing repeats (the very feature it's sold on).
  - Subscription gripes — "a monthly subscription to this app is more than a subscription to most streaming platforms"; one reviewer also flagged the iPad keyboard being unusable in landscape.
- _Implication for CastCircle:_ coldRead's #1 complaints are audio glitches and intermittent auto-advance — the two things CastCircle must nail flawlessly, since they're exactly what reviewers rave about when they work.
- Source: App Store id1264354117; coldreadapp.com.

### Script Rehearser — the Android/cross-platform volume leader
- Cross-platform (iOS + Android), live since 2014, still updated **March 2026**. **100K+ Google Play installs**, ~1,900–2,070 ratings at **~4.05★** — the strongest *download-proxy* of any cross-platform competitor.
- Free to download; offers **built-in synthesized voices OR your own recordings**, type/import scripts, and three rehearsal modes (Listen Along / Wait For Me / Repeat for Confirmation). A paid tier (~$10–$30 reported in roundups) unlocks more.
- The closest "mass market, both stores, free entry" competitor; weaker on modern AI voices and auto-advance polish.
- **Loved (top positive review themes):**
  - Genuinely works for memorization — users report being able to "memorize lines overnight"; the rehearsal modes (Listen Along / Wait For Me / Repeat) are the draw.
  - Computerized voices seen as a feature, not a bug — actors like that the synthesized read "keeps them from expecting the same voice and read" they'll get in the room.
  - Helpful support and clear payoff — "if you're willing to put in the work to set it up, it's a big help."
- **Pain points (top negative review themes):**
  - Buggy/clunky import is the dominant complaint — importing sides is unreliable: lines come in "messed up, absent, or assigned to the wrong person," and it chokes on margin text like "Sides by Breakdown Services" and Start/End marks, requiring manual cleanup.
  - Slow, fiddly setup — getting a scene ready "can take a long time," a friction point for last-minute auditions.
  - "Okay but not great" — even fans temper their praise, calling it serviceable rather than polished.
- _Implication for CastCircle:_ Script Rehearser's biggest weakness is exactly the import step — frictionless on-device OCR with reliable character detection is the clearest place to beat the Android volume leader.
- Source: scriptrehearser.com; Play store com.rehearser.rehearser3free; Similarweb/AppBrain.

### Run Lines With Me — cheap subscription, high satisfaction
- iOS only, developer Nonzero Solutions. **1,300+ ratings at 4.7★** — the highest rating among high-volume apps.
- Record the scene once, mark your lines, playback leaves gaps; speed control, background/Bluetooth.
- **Aggressively cheap**: free (10 recordings / 150 min), then $1.99/3mo, $3.99/6mo, **$4.99/year**. Reviewers explicitly praise it for being affordable vs. competitors.
- Lacks AI voices / OCR import / speech-recognition auto-advance — it's the polished *budget recording* app. Sets a low price anchor actors notice.
- **Loved (top positive review themes):**
  - The gap-playback workflow just works — "it plays the line before yours and leaves a gap for you to say your line"; working actors call it the best of the apps they've tried.
  - Price is the headline praise — "subscriptions are actually reasonably priced and NOT $100 a year"; reviewers explicitly contrast it favorably with pricier rivals.
  - Dead-simple and portable — one-touch recording with no scene/character setup, plus folders/labels; "I could literally be rehearsing wherever I go."
- **Pain points (top negative review themes):**
  - Paywall friction — "awesome app, hate that you have to pay" once you exceed the free 10-recording / 150-minute ceiling.
  - Recording-count bug — multiple users hit a state where deleted recordings still counted against the free limit (dev responds and offers email support).
  - No AI voices / no script text view — it's recording-only, so visual learners and those wanting auto-advance look elsewhere.
- Source: App Store id1269241182.

### Rehearsal Pro — the legacy "professional" premium incumbent
- Developer Sotto Voce Filmworks. Marketed as "#1 best-selling app for professional actors," NYT/Backstage press, claims **1.2M+ cumulative scripts rehearsed**.
- **$19.99 one-time, no IAP** — the high end of one-time pricing and the de-facto ceiling for "buy once."
- Deep feature set: highlight/blackout, record + teleprompter-scroll playback, beat marks, annotations, Car Mode, PDF/Word + Adobe scan, MP3 export, cross-device sync.
- But store footprint is modest/soft: **66 ratings at 3.6★** (bugs cited in reviews). Strong brand, aging UX.
- **Loved (top positive review themes):**
  - Core line-learning workflow is trusted by pros — "I am totally reliant on the core functionality: highlighting my lines, recording the scenes"; auto-replay is valued for hands-free practice while driving or doing dishes.
  - Cross-device sync — appreciated for keeping scripts/scenes in progress across devices.
  - Long-term loyalty — veteran actors credit it with booking success and stick with it for years.
- **Pain points (top negative review themes):**
  - Crashes and freezing dominate recent reviews — "freezing, shutting down, same complaints as all the recent reviews"; the app locks up on setup screens, and one user's audition morning during pilot season was disrupted by it. Updates promising fixes reportedly reintroduced bugs (e.g., lost auto-replay).
  - Import is confusing/unreliable — the camera icon redirects to Adobe Scan, "Import to Rehearsal Pro" appears only "50/50," and users hit "Error writing file."
  - $20 one-time feels unjustified given the bugs — called "insulting" and "ridiculous for an app"; basic features (rotate, email/print) reported missing or undocumented.
- _Implication for CastCircle:_ The legacy "professional" incumbent is dragged down to 3.6★ by stability — reliability alone is a beatable bar.
- Source: App Store id1116896197; rehearsal.pro; AppGrooves (204 reviews).

### LineLearner — long-running budget cross-platform
- Developer Peter Allday. iOS **135 ratings / 4.3★**; Android weaker (~**10K+ installs, ~2.8–2.9★, ~304 ratings**).
- **One-time $3.99 (iOS) / ~$5.49 (Android)**, no subscription, no ads — a deliberate value play.
- Record scene, gap-out your part, pitch-shift other characters, PDF/Word import, and notably **share recordings with scene partners** (cast collaboration — directly relevant to CastCircle's sharing feature).
- iOS last updated Jul 2024; Android lagging. Beloved but dated.
- **Loved (top positive review themes):**
  - Trusted value play — called "a must for actors" and "the best of the line learning app options available," with the flat one-time fee and "no subscriptions, no ads" repeatedly cited as the reason to choose it.
  - Easy record + pitch-shift — actors like how simple it is to record a scene and pitch-shift other characters so they're distinguishable.
  - Cross-device sync — an edge over the iOS-only field.
- **Pain points (top negative review themes):**
  - No script text view / no import — purely audio, so visual learners struggle and everything must be recorded by hand, which "becomes tedious for longer scenes."
  - Audio bugs, especially on Android — inconsistent volume, audio clipping, and device-specific playback issues (Samsung S8/S9, Pixel 3) that the developer's own help docs walk users through; this maps to the weak ~2.8★ Android rating.
  - Clunky editing — the correction/editing interface is described as unintuitive.
- Source: App Store id368070258; Play com.alldayapps.android.linelearner; linelearner.wordpress.com (support docs); actorsjunction.com.

### ScenePartner: AI Line Reader — the premium-priced AI newcomer
- Developer Gumball LLC. Very new (v1.2, 2024–25), only **6 ratings (5.0★)** so far; claims 10,000+ actors.
- Free for **3 scripts**, then the most expensive tiers in the market: **Plus $19.99/mo or $199.99/yr; Pro $44.99/mo or $459.99/yr.**
- AI voice reads partner lines, speech recognition follows you, import sides, teleprompter (XL text / high contrast), in-app self-tape.
- Tests whether actors will pay near-prosumer SaaS prices. CastCircle can credibly position as "the same auto-advance experience, on-device, at a fraction of the price."
- **Loved (top positive review themes):**
  - AI voice + speech recognition exceed expectations — "pleasantly surprised how good the speech recognition is as well as the AI voice reading back the lines"; readers have "really improved" with updates and feel "very responsive to my natural speech."
  - Easy onboarding and responsive devs — "getting started was super easy," with the team called "very helpful updating it"; the native app is described as "next level" vs. the web version.
- **Pain points (top negative review themes):**
  - Too few reviews to assess negatives — only 6 ratings (all 5★), so there is no recurring complaint signal yet; treat the rating as not-yet-meaningful. The clearest external knock is price: Plus $19.99/mo and Pro $44.99/mo are the steepest in the category (the cloud ElevenLabs voices behind it carry per-use cost).
- Source: App Store id6737419907; scenepartner.ai; elevenlabs.io/blog/scenepartner.

### ActingPal: AI Scene Partner — AI features, execution problems
- Developer Acting Pal Ltd. **7 ratings at 1.9★** — quality/stability complaints (failed playback, unstable self-tape, slow support).
- Free; Pro **$9.99/mo (promo $8.99)**.
- Notable that it markets **on-device text extraction** for privacy, AI voices, responsive cueing, scene sharing, letter-reveal memorization. A cautionary tale: AI ambitions undercut by execution — an opening for a polished on-device app.
- **Loved (top positive review themes):**
  - The vision and voices land — "like the AI voices that they have and they're simple to use"; reviewers see the potential ("I think it could be useful," "app could be great if it just worked").
- **Pain points (top negative review themes):**
  - Stability is the killer — even the sample script fails ("the lines just kept saying 'failed to load'"), and users report it "sometimes works, but only sometimes."
  - Core features unavailable — self-tape gets disabled as "not stable enough to operate," so trialers can't complete the primary task.
  - Paywall before it works — "not usable at all unless you pay money for it," and support is unresponsive ("asked a simple question... weeks ago and have gotten no reply") — the drivers of the 1.9★ rating.
- _Implication for CastCircle:_ ActingPal shows that on-device AI ambition plus poor execution craters the rating to 1.9★ — a polished, reliable on-device app wins this matchup on execution alone.
- Source: App Store id6736730265.

### Off Book / Offbook (offbook.co) — the prestige web AI tool
- Web app (app.offbook.co); mobile availability unclear. Markets "actors from Juilliard, Yale, NYU, LAMDA, RADA, RSC."
- AI scene partner **powered by ElevenLabs** (cloud TTS), PDF/image import, a "Genie" subtext/motivation assistant, synced self-tape cues. Freemium (pricing page gated).
- Strong brand/prestige positioning; cloud-dependent (privacy + latency + per-use cost are weaknesses CastCircle can exploit). Distinct from the abandoned **Off Book!** iOS app (id921046788, last updated 2017).
- **Loved (top positive review themes):**
  - "Built by actors" credibility — "you can clearly see in the quality of the application that it was built by actors who know what they're doing."
  - A patient, always-available partner — "Offbook never gets frustrated when I need to repeat sections over and over," and it ends having to "bug friends to read with them."
- **Pain points (top negative review themes):**
  - No native App Store / Play presence means no first-party store review corpus — too few public reviews to assess directly; complaints are inferred from its underlying tech.
  - Cloud TTS (ElevenLabs) inherits ElevenLabs' documented gripes — "inconsistent tone across sessions," weak handling of numbers/abbreviations/accents, and billing/credit-rollover frustration ("bait and switch," "scammy") — i.e., privacy, latency and per-use cost are structural weaknesses.
- _Implication for CastCircle:_ The prestige web tools lean on cloud voices whose own users complain about tone drift and billing — an on-device pipeline sidesteps all of it.
- Source: offbook.co; ElevenLabs reviews (Trustpilot, Product Hunt).

### Slatable — self-tape app that bolted on an AI scene partner
- iOS, since 2016, **674 reviews**. Primarily a self-tape/audition tool, now with a **ScenePartner AI voice-changer** (record partner lines, revoice them naturally).
- Clear tiering: Free (1 audition/mo), **Basic $4.99/mo ($50.90/yr)**, **Premium $9.99/mo ($95.90/yr)**; AI voice currently bundled free into Premium (limited time, 2-hr monthly reset).
- Demonstrates the **$5 / $10 per-month, ~$50 / ~$95 per-year** sweet spot the market is converging on.
- **Loved (top positive review themes):**
  - The AI voice-changer convinces — "the voice converter actually sounds like a real person"; it "transforms it into a completely different voice that feels real and engaging."
  - All-in-one self-tape relief — the teleprompter plus doing "everything in one app is game changing," and it has "alleviated stress around self tapes" (674 reviews back a solid reputation).
- **Pain points (top negative review themes):**
  - AI revoicing is slow and not yet a clear win — "the new AI voice takes much longer to record and doesn't seem any better (yet)."
  - You still record everything yourself first — because it's a voice-changer (not a generator), you must record all the other lines before revoicing, and "that setup time adds up."
  - Editing data loss — "the scene audio option will delete lines if you try to go back and edit," and "the 'reader' lines are much louder than my lines."
- Source: App Store id1080031696; slatable.com/priceplans.html.

### RehearseNow.ai & Linus — cloud AI scene partners, ~$8–15/mo
- **RehearseNow.ai**: web, cloud AI voices, cross-device sync, self-tape. **$15/mo or $100/yr (~$8.33/mo)**, 7-day trial.
- **Linus**: iOS/Android/web, AI scene partner with **speech-recognition auto-advance**, self-tape + teleprompter, table read, real (paid) voice actors, unified cross-platform sync. Free; **$9.99/mo unlimited**; 3-day passes from $1.99.
- Both validate **~$8–$15/mo / ~$100/yr** as the standard AI subscription, and both are **cloud-based** — i.e., directly beatable by an on-device offering on privacy/offline/cost.
- **Linus — Loved (top positive review themes):**
  - Natural per-character voices — "different voices for different characters that don't sound robotic is amazing"; the AI "adapts to your performances," and the upload handles non-standard formats (e.g., musicals) without reformatting.
  - Fast real auditions — "a 4 page audition in just under 30mins," with the integrated self-tape and "super easy/seamless" workflow praised (4.5★ across ~40 ratings).
- **Linus — Pain points (top negative review themes):**
  - Crashes and lost progress — the app "crashes when working on scenes with too much data," losing progress; uploading and speech recognition "gets stuck often."
  - Recording blocked by audio threshold — users "can't record a scene if audio passes a threshold"; recorded audio sometimes comes out "way to quiet" / "scuffed."
  - Price — described by a reviewer as "insanely expensive."
- **RehearseNow.ai — Loved:** voices called "appealing" with "excellent" enunciation and "very good" line timing; one actor credits it with booking a network-TV role (ABC's *Will Trent*), calling it "a game changer."
- **RehearseNow.ai — Pain points:** too few first-party reviews to assess (web tool, no app-store review corpus); the structural knock is its cloud dependence (privacy, latency, $100/yr cost).
- Sources: rehearsenow.ai; getlinus.app; App Store id6742599484 (Linus); futurepedia.io/tool/rehearsenow.

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
- ScenePartner: AI Line Reader — App Store: https://apps.apple.com/us/app/scenepartner-ai-line-reader/id6737419907 ; site: https://scenepartner.ai/ ; ElevenLabs case study: https://elevenlabs.io/blog/scenepartner
- ActingPal: AI Scene Partner — App Store: https://apps.apple.com/us/app/actingpal-ai-scene-partner/id6736730265
- Off Book / Offbook — https://www.offbook.co/
- Off Book! (legacy iOS) — App Store: https://apps.apple.com/us/app/off-book/id921046788
- Rafy — App Store: https://apps.apple.com/us/app/rafy-self-tape-acting-reader/id6478787835
- Rehearser — https://rehearser.co (via Scriptation roundup)
- Slatable — App Store: https://apps.apple.com/us/app/slatable-audition-app/id1080031696 ; price plans: https://slatable.com/priceplans.html
- RehearseNow.ai — https://rehearsenow.ai/ ; review: https://www.futurepedia.io/tool/rehearsenow
- Rehearsal Pro — review aggregator (204 reviews): https://appgrooves.com/ios/1116896197/rehearsal-pro/sotto-voce-filmworks-inc/negative ; App Store reviews: https://apps.apple.com/us/app/rehearsal-pro/id1116896197?see-all=reviews
- LineLearner — review/guide: https://actorsjunction.com/resource/linelearner ; Android support/known-issues docs: https://linelearner.wordpress.com/instructions-for-android/ ; https://linelearner.wordpress.com/faq-linelearner-for-android/
- ElevenLabs (cloud TTS behind Offbook/ScenePartner) reviews — https://www.trustpilot.com/review/elevenlabs.io ; https://www.producthunt.com/products/elevenlabs/reviews
- Linus — https://www.getlinus.app/blog/the-best-ai-tools-for-actors-in-2026 ; App Store reviews: https://apps.apple.com/us/app/linus-learn-lines-self-tape/id6742599484?see-all=reviews
- ActOnCue — https://actoncue.com/ ; roundup: https://actoncue.com/blog/best-line-learning-apps
- Backstage roundup ("7 Line Memorization Apps"): https://www.backstage.com/magazine/article/line-memorization-apps-actors-70280/
- Scriptation roundup ("16 Best Apps for Actors in 2026"): https://scriptation.com/blog/best-apps-for-actors/
- Qonversion (LineLearner price intel): https://qonversion.io/apps/ios/linelearner/368070258
- Self-e-Tape (self-tape apps 2026): https://selfetape.com/blog/best-self-tape-apps-for-actors-2026

_Note on confidence: App Store rating counts/averages and Google Play install buckets are from live store listings (June 2026) and are reliable. Tiered subscription prices were read from store IAP listings and developer pricing pages. "Est. downloads," prestige/usage claims (e.g., "10,000+ actors," "1.2M+ scripts"), and a few paid-tier prices for cross-platform apps (Script Rehearser's paid tier) are vendor- or roundup-reported and should be treated as approximate. coldRead's listing landscape is fragmented across multiple bundle IDs/publishers; the ~3,700-rating figure refers to the established id1264354117 listing._

_Note on the "Loved / Pain points" review blocks: themes reflect recurring patterns across multiple App Store / Google Play reviews and third-party roundups read in June 2026. Text in quotation marks is verbatim (or near-verbatim) review/quote wording captured from store reviews and review articles; un-quoted bullets are paraphrased summaries of repeated themes. Where an app has too few reviews to support a complaint signal (ScenePartner — 6 ratings; RehearseNow.ai and Offbook — web tools with no first-party store review corpus), this is stated explicitly rather than inferring negatives. No quotes were fabricated; where a verbatim line could not be confirmed, the theme is given without quotation marks._

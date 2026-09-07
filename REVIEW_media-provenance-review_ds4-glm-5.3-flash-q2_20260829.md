# Pi sweep review — CastCircle

Exhaustive per-file pass: 2 code files across 1 batches — model ds4/GLM-5.3-Flash-Q2:off — 2026-08-30.

## Findings

- [medium] scripts/test_silence_trim.swift:124-125 — `try!` on network download and file write — a failed fetch or write crashes the CLI with no diagnostic; replace with `try?`/error print and exit(1) — reachability: operator running the script (low).
- [medium] scripts/test_silence_trim.swift:123-126 — fixed temp path `/tmp/test_audio_trim.m4a` — concurrent runs or a pre-existing file collide; the write overwrites whatever is there and the analysis reads the wrong bytes — use `FileManager.default.temporaryDirectory` with a unique name — reachability: operator (low).
- [medium] scripts/test_silence_trim.swift:33 — hardcoded `sampleRate = 44100.0` while the reader output is 16-bit PCM from the actual track — a 48 kHz source mislabels every window's time offset, so speechStart/speechEnd (and the trim range at 104-106) are wrong by up to ~9% — derive sample rate from the track's `naturalAudioFrequency`/output format — reachability: operator (low), but silent data loss (wrong trim) justifies medium.
- [medium] scripts/test_silence_trim.swift:46-47 — `ptr.withMemoryRebound(to: Int16.self, capacity: length / 2)` rebinds the raw Int8 pointer without checking alignment or that `length` is even; odd-length or misaligned block buffers read garbage samples into the RMS windows — guard `length % 2 == 0` and alignment before rebinding — reachability: operator (low).
- [low] scripts/test_silence_trim.swift:52 — RMS accumulates `Float($1) * Float($1)` on Int16 values; worst-case square is ~1.07e9 which fits Float's 24-bit mantissa poorly at large sums, biasing the threshold — accumulate in Double and convert — reachability: operator (low).
- [low] scripts/test_silence_trim.swift:141-142 — output written to fixed `/tmp/trimmed_output.m4a`; same collision/overwrite concern as the input temp path — use a unique temp name — reachability: operator (low).
- [low] scripts/test_silence_trim.swift:155-156 — `attributesOfItem(atPath:)` size cast via `as? Int` with `?? 0` fallback silently reports 0KB on failure, making the "was X KB" line misleading — surface the error or omit the line — reachability: operator (low).
- [info] scripts/test_silence_trim.swift:120-127 — script accepts arbitrary `http(s)` URLs and downloads them with no scheme/host restriction; if this pattern is copied into production code it becomes an unconstrained fetch — verify it stays test-only.
- [low] scripts/test_pdf_import.swift:71,79,87,95,108 — `try!` on NSRegularExpression construction — a malformed literal would crash the tool; these are compile-time constants so risk is low, but prefer `do/catch` with a diagnostic — reachability: operator (low).
- [low] scripts/test_pdf_import.swift:74,82,90,98 — `NSRange(cleaned.startIndex..., in: cleaned)` is re-derived from the *mutated* string each step, which is correct here, but the header/page-number patterns use `.anchorsMatchLines` with `^...$` against the whole text; multi-line blocks that *begin* a line are matched only at line starts, so a header mid-line survives cleanup — acceptable for a test harness; note only if the same regex is reused in the Flutter parser.
- [info] scripts/test_pdf_import.swift:5 — usage string references `sample-scripts/macbeth_PDF_FolgerShakespeare.pdf`; the script itself takes argv[1], so no defect — verify the referenced sample exists if this is documented as the canonical invocation.

## Coverage
scripts/test_pdf_import.swift — findings: 2
scripts/test_silence_trim.swift — findings: 8

## Run stats

input 5579 tok (+1089 cached), output 856 tok — sync requests, discounted — 2 files in 0m (156.5 files/h, 0.8 min/batch)

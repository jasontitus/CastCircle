# Reference Character/Line Data for Parser Validation

Sources:
- [Open Source Shakespeare](https://www.opensourceshakespeare.org/views/plays/characters/chardisplay.php)
- [PlayShakespeare.com](https://www.playshakespeare.com/study/biggest-roles)
- [Wikipedia character lists](https://en.wikipedia.org)
- [StageAgent](https://stageagent.com)
- [SparkNotes](https://www.sparknotes.com)

## Shakespeare (speeches from Open Source Shakespeare)

| Play | Acts | Speaking Roles | #1 | Speeches | #2 | Speeches | #3 | Speeches |
|------|------|---------------|-----|---------|-----|---------|-----|---------|
| Hamlet | 5 | ~30 | Hamlet | 358 | Horatio | 109 | Claudius | 102 |
| Romeo and Juliet | 5 | ~20 | Romeo | 163 | Juliet | 118 | Nurse | 90 |
| Othello | 5 | ~15 | Othello | 274 | Iago | 272 | Desdemona | 165 |
| King Lear | 5 | ~20 | Lear | 188 | Kent | 127 | Gloucester | 118 |
| Macbeth | 5 | ~30 | Macbeth | 146 | Lady Macbeth | 59 | Macduff | 59 |
| Midsummer Night's Dream | 5 | ~20 | Bottom | ~50 | Theseus | ~48 | Oberon | ~40 |
| Much Ado About Nothing | 5 | ~20 | Don Pedro | 135 | Benedick | 134 | Claudio | 125 |
| Twelfth Night | 5 | ~15 | Sir Toby | 152 | Viola | 121 | Olivia | 118 |
| The Tempest | 5 | ~15 | Prospero | 114 | Sebastian | 67 | Miranda | 50 |

## Ibsen

| Play | Acts | Speaking Roles | Top Character | Notes |
|------|------|---------------|---------------|-------|
| A Doll's House | 3 | 6-8 | Nora | 6 named + maid + porter |
| Hedda Gabler | 4 | 7 | Hedda | Hedda, Tesman, Brack, Løvborg, Mrs. Elvsted, Miss Tesman, Berte |
| Ghosts | 3 | 5 | Mrs. Alving | Mrs. Alving, Oswald, Manders, Engstrand, Regina |

## Oscar Wilde

| Play | Acts | Speaking Roles | Top Character | Notes |
|------|------|---------------|---------------|-------|
| Importance of Being Earnest | 3 | 9 | Jack | Jack, Algernon, Gwendolen, Cecily, Lady Bracknell, Miss Prism, Dr. Chasuble, Lane, Merriman |
| An Ideal Husband | 4 | ~12 | Lord Goring | |
| Lady Windermere's Fan | 4 | ~12 | Lady Windermere | |

## George Bernard Shaw

| Play | Acts | Speaking Roles | Top Character | Notes |
|------|------|---------------|---------------|-------|
| Pygmalion | 5 | ~12 | Higgins | Higgins, Eliza, Pickering, Doolittle, Mrs. Higgins, Mrs. Pearce, etc. |
| Arms and the Man | 3 | 6 | Raina | Raina, Bluntschli, Sergius, Louka, Nicola, Catherine |
| Candida | 3 | 6 | Morell | Morell, Candida, Marchbanks, Burgess, Proserpine, Lexy |

## Other Classics

| Play | Author | Acts | Speaking Roles | Top Character |
|------|--------|------|---------------|---------------|
| Cyrano de Bergerac | Rostand | 5 | ~25 | Cyrano |
| Doctor Faustus | Marlowe | 5 | ~14 | Faustus |
| She Stoops to Conquer | Goldsmith | 5 | ~12 | Marlow or Tony Lumpkin |
| School for Scandal | Sheridan | 5 | ~15 | Sir Peter Teazle |
| The Rivals | Sheridan | 5 | ~12 | Captain Absolute |
| Oedipus Rex | Sophocles | 1 (continuous) | ~8 | Oedipus |
| Way of the World | Congreve | 5 | ~12 | Mirabell |
| Cherry Orchard | Chekhov | 4 | ~15 | Lubov (Lyubov) |
| Tartuffe | Molière | 5 | ~10 | Orgon or Dorine |

## Parser Results vs Reference (2026-03-18)

| Play | Ref Chars | Found | Ref Acts | Found | Top Match? | Grade |
|------|-----------|-------|----------|-------|-----------|-------|
| Hamlet | ~30 | 35 | 5 | 5 | HAMLET ✓ | A |
| Romeo & Juliet | ~20 | 31 | 5 | 5 | ROMEO ✓ | A |
| Othello | ~15 | 25 | 5 | 5 | IAGO ✓ | A |
| King Lear | ~20 | 26 | 5 | 5 | LEAR ✓ | A |
| Macbeth | ~30 | 38 | 5 | 5 | MACBETH ✓ | A |
| Midsummer | ~20 | 33 | 5 | 5 | THESEUS ~ | B |
| Much Ado | ~20 | 24 | 5 | 5 | BENEDICK ✓ | A |
| Twelfth Night | ~15 | 19 | 5 | 5 | SIR TOBY ✓ | A |
| The Tempest | ~15 | 5 | 5 | 5 | II ✗ | F |
| A Doll's House | 6-8 | 12 | 3 | 3 | NORA ✓ | A |
| Hedda Gabler | 7 | 10 | 4 | 4 | HEDDA ✓ | A |
| Ghosts | 5 | 7 | 3 | 3 | MRS ~ | A |
| Earnest | 9 | 13 | 3 | 4 | JACK ✓ | A |
| Ideal Husband | ~12 | 16 | 4 | 4 | LORD GORING ✓ | A |
| Lady Windermere | ~12 | 16 | 4 | 4 | LADY WINDERMERE ✓ | A |
| Arms & the Man | 6 | 10 | 3 | 3 | RAINA ✓ | A |
| Candida | 6 | 6 | 3 | 3 | MORELL ✓ | A |
| Pygmalion | ~12 | 17 | 5 | 5 | HIGGINS ✓ | A |
| Cherry Orchard | ~15 | 32 | 4 | 4 | IRINA ~ | B |
| Cyrano | ~25 | 148 | 5 | 5 | CYRANO ✓ | B |
| Doctor Faustus | ~14 | 6 | 5 | 1 | FAUSTUS ✓ | D |
| She Stoops | ~12 | 23 | 5 | 5 | MARLOW ✓ | A |
| School for Scandal | ~15 | 19 | 5 | 5 | SIR PETER ✓ | A |
| The Rivals | ~12 | 13 | 5 | 5 | ABSOLUTE ✓ | A |
| Oedipus Rex | ~8 | 22 | 1 | 1 | OEDIPUS ✓ | B |
| Way of the World | ~12 | 18 | 5 | 63 | MIRA ~ | B |
| Tartuffe | ~10 | 3 | 5 | 5 | MR ✗ | F |

**Success Rate: 22/28 A/B (79%), up from 20/28 (71%)**

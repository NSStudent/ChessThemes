# ChessThemes

Detects tactical and strategic **themes** in a chess game from its moves. Each theme comes with a **strength** from 0 to 1 and the **plies** where it shows up, plus a compact `UInt64` bitset to store in a search index.

It is a rule-based, engine-free answer to the "strategic themes" of ChessBase 18 (sorted by *Theme Strength*) and to part of the CQL Search of ChessBase 27: rules over the positions, computed with bitboards.

- Swift 6, iOS 18 / macOS 15.
- Depends on [fischer-core](https://github.com/NSStudent/fischer-core) `from: "0.4.0"` only to accept `[ResolvedMove]`; the detector replays the game on its own bitboards.
- One `ThemeScanner` per thread; it reuses its buffers between games and allocates nothing per ply.

## Installation

```swift
.package(url: "https://github.com/NSStudent/ChessThemes.git", from: "0.1.0"),
```

## API

```swift
import ChessThemes
import FischerCore

let scanner = ThemeScanner()                         // one per thread, reusable
let report = try scanner.report(of: moves,           // [ResolvedMove] or [ThemeMove]
                                startFEN: nil,       // optional FEN of the starting position
                                result: .whiteWins)  // optional, see below

for hit in report.hits {
    print(hit.theme, hit.side, hit.strength, hit.plies)   // e.g. fork white 0.97 [41]
}
let bits: UInt64 = report.themes.rawValue            // bits 0–31 white, 32–63 black

// Just the bitset, without the list of hits (what an indexer needs):
let set = try scanner.themes(of: moves, result: .draw)
if set.contains(.minorityAttack, side: .white) { … }
let anySide: UInt32 = set.ignoringSides              // "the theme, for either side"

// Look for a few themes only (faster):
let tactics = ThemeScanner(themes: ThemeSet(themes: [.fork, .pin, .discoveredAttack]))
```

- `ThemeMove(from:to:promotion:)` is the neutral input: squares 0–63 (a1 = 0), promotion 0 none / 1 N / 2 B / 3 R / 4 Q. Castling is the king moving two files (as in fischer-core). `ThemeMove(uci:)` reads UCI. There are `UnsafeBufferPointer<ThemeMove>` overloads to avoid copies.
- **Pass the game result.** `fortress` needs it, and `sacrifice`, `exchangeSacrifice`, `matingAttack` and several strengths use it to filter blunders and to reward the side that wins.
- Plies count from 1 = first move of the list, also when the game starts from a FEN with Black to move.
- `ThemeHit.plies`: tactical themes, up to four plies where the theme was detected; strategic themes, `[first, last]` ply of the longest stretch.
- `ThemeReport.quantizedStrength(_:side:)` gives the strength in 4 bits (1–15) in case an index wants to store strengths next to the bitset.
- `Theme.spanishName` gives a Spanish label for each theme.
- Errors: `ThemeError.invalidFEN` and `ThemeError.illegalMove(index:)` (no piece of the side to move on the origin square). The detector does not check full legality; it expects validated moves (fischer-core's are).

## Catalog

The raw values are the index format: they are never renumbered. Bits 11–15 (tactical) and 28–31 (strategic) are free.

`S` = the side that has the theme. "Settled material" = the balance after the chain of captures that starts with that move (up to 8 captures in a row). Values P 1, N 3, B 3, R 5, Q 9. "Middlegame" = each side has at least 13 of non-pawn material.

### Tactical (bits 0–10)

| Bit | Theme | Rule | Strength |
|--:|---|---|---|
| 0 | `sacrifice` | In a quiet moment (no captures in the 2 previous plies, S not in check and not ≥ 2 ahead), S moves a N, B, R or Q that was not already en prise to a square where it is captured on the next ply. After the captures on that square S has ≥ 2 less material than before and is not more than 1 ahead, and the ≥ 2 deficit holds on every ply up to 4 plies later. Not counted if S loses the game, or if the piece is given for a passed pawn on its 6th/7th rank (that is stopping a promotion). | 0.25 + 0.08·material given, +0.15 if S wins |
| 1 | `exchangeSacrifice` | Same quiet context; the rook S moves is captured on its arrival square and, after the captures there, S has one rook less and the opponent one minor piece less (queens and the rest equal), and it stays so for 4 plies. Not counted if the captured minor was giving check or attacking the king or queen (a forced exchange), if S was already ≥ 2 ahead (giving material back), or if the rook captured nothing and S loses the game (an oversight). | 0.6, +0.2 if S doesn't lose, +0.2 if S wins |
| 2 | `matingAttack` | Checkmate on the board by S (strength 1, plies = S's last checks). Without mate: S wins, gave ≥ 3 checks in the last 12 plies, has a queen, ≥ 2 of its pieces attack the king zone, and was not ≥ 3 ahead when the checks started. In both cases the defender has ≥ 5 of non-pawn material after the first check (mopping up a bare king doesn't count). | 1 with mate; 0.6–0.85 without |
| 3 | `oppositeCastlingAttack` | Kings castled on opposite sides; then, with its queen on and ≥ 20 non-pawn material per side, S pushes (without capturing) ≥ 2 pawns on the files of the enemy king's wing to its 4th rank or further, each push ≤ 12 plies after the previous one. | 0.3 + 0.12·pushes, +0.1 if S wins |
| 4 | `pin` | The piece S moves creates a new pin (an enemy piece, not a pawn, between it and the enemy king or queen; a queen does not pin to a queen). Within 6 plies S captures the pinned piece, the pin still stands until then, and S stays ≥ 2 up on every ply until 4 plies after the captures on that square. | 0.3 + 0.075·gain |
| 5 | `fork` | The piece S moves attacks ≥ 2 enemy pieces worth more than it (the king counts) or undefended (not pawns). Within 5 plies that same piece captures one of them and S gains ≥ 2 of settled material. | 0.3 + 0.075·gain |
| 6 | `discoveredAttack` | When S's piece leaves its square, a bishop/rook/queen of S now attacks an enemy piece worth more (or the king, or an undefended piece). Within 4 plies S gains ≥ 2 by capturing the target (or, after a discovered check, with the piece that moved), or mates. | 0.3 + 0.075·gain, +0.1 with check |
| 7 | `promotionRace` | With endgame material (≤ 13 non-pawn per side), a passed pawn of each side reaches its 7th rank without capturing and survives the reply (or promotes), ≤ 4 plies apart, with the other side's pawn still on its 7th (or just promoted). Marked for both sides. | 1 if both promote, 0.8 one, 0.5 none |
| 8 | `greekGift` | In a quiet moment, Bxh7+ (Bxh2+) taking a pawn with the enemy king on g8 (g1); the bishop was not attacked; the king takes it or it is declined; within 6 plies S plays Ng5 (Ng4) or Qh5 (Qh4), captures no other piece away from g5 (g4), and both queens are still on the board. | 0.6, +0.2 if accepted, +0.2 if S wins |
| 9 | `backRankMate` | Rook or queen mate on the king's first rank, with the squares in front of the king taken by its own pieces, ≥ 2 of them pawns. | 1 |
| 10 | `smotheredMate` | Knight mate with every square around the king taken by its own pieces. | 1 |

### Strategic (bits 16–27)

Measured over stretches of consecutive plies; a hit reports the longest stretch, and the strength extras (doubling, penetration, 6th rank…) are those of that stretch.

| Bit | Theme | Rule (in each position) | Min. stretch (plies) | Strength |
|--:|---|---|--:|---|
| 16 | `minorityAttack` | In the middlegame, S pushes its b-pawn to its 5th rank (b4-b5 / …b5-b4) without capturing, with fewer pawns than the opponent on a–c, no c-pawn of its own, an enemy b-pawn, the enemy c-pawn on its 3rd rank (c6 / c3), and locked d-pawns (d4 against d5). | move | 0.7, +0.2 if bxc follows, +0.1 if S wins |
| 17 | `isolatedQueenPawn` | Middlegame with ≥ 5 pawns each; S has a single d-pawn, on d4 or d5, with no c- or e-pawns of its own; the opponent has no d-pawn, and the d-pawn is not passed (an enemy c- or e-pawn is ahead of it). | 16 | 0.4 + length/80 (max 0.4), +0.2 if it pushes to d5 |
| 18 | `bishopPair` | S has bishops on both colors; the opponent has ≤ 1 bishop, ≥ 1 knight and ≥ 6 non-pawn material. | 20 | 0.3 + length/100 (max 0.5), +0.2 if S wins |
| 19 | `goodVsBadBishop` | One bishop each, the same rooks, queens and knights, and level material (±1). The opponent has ≥ 3 pawns on its bishop's color (≥ 60 % of its pawns) and ≥ 2 of them, on c–f, blocked by S's pawns; S has ≤ ⅓ of its pawns on its bishop's color. | 12 | 0.4 + length/60 (max 0.4), +0.2 if S wins |
| 20 | `outpostKnight` | S's knight on b–g of its 5th–6th ranks, or on c–f of its 4th rank blocking an enemy pawn; supported by a pawn and on a square no enemy pawn can ever attack; the opponent has ≥ 6 in pieces not counting the queen. | 8 | 0.3 + length/60 (max 0.4), +0.2 if it reaches the 6th |
| 21 | `openFile` | With ≥ 10 pawns on the board, S's rook on a pawnless file where the opponent has no rook or queen, while the opponent keeps a rook or queen; on that same file S doubles heavy pieces or gets a rook to the 7th/8th. | 16 | 0.3 + length/60 (max 0.3) + 0.25 doubling / 0.2 penetration / 0.35 both |
| 22 | `seventhRank` | S's rook on its 7th, with the enemy king on the 8th and some enemy pawn on the 7th, or with ≥ 2 enemy pawns on the 7th; and the rook attacks along the rank an enemy pawn or a flight square of the king. | 6 | 1 with two heavy pieces on the 7th; else 0.5 + length/30 (max 0.3) |
| 23 | `passedPawn` | S has a passed pawn on its 6th or 7th rank for ≥ 6 plies, or promotes. If the stretch ends with the game, S loses and doesn't promote, it needs ≥ 10 plies. | 6 | 0.5 (6th) / 0.7 (7th), +0.1 supported, + length/50 (max 0.2), +0.1 if it promotes |
| 24 | `spaceAdvantage` | Middlegame with ≥ 6 pawns each; S has ≥ 2 non-passed c–f pawns on its 5th rank or further, the opponent none of its c–f pawns on its own 5th, one of S's is blocked by an enemy pawn and a d- or e-pawn of them is protected by another pawn. | 16 | 0.4 + length/80 (max 0.4) + 0.1 per extra pawn |
| 25 | `kingWalk` | With no promotion so far, S's king goes to its 4th rank or further with no enemy check in the 4 previous plies; the opponent has a queen and ≥ 14 non-pawn material, S ≥ 13, and S is not ≥ 5 behind. It needs (≥ 2 such moves and the 5th rank) or the 6th rank. | game | 0.4 / 0.6 / 0.8 by rank, +0.2 if S wins |
| 26 | `fortress` ⚠️ experimental | Draw; S ends 2 to 4 material down and has been so for the last ≥ 20 plies; S is not a bare king; the stronger side has ≤ 14 non-pawn material, at least the same pieces of each type as S, and also a pawn, or one more rook or queen. Not counted with ≥ 3 checks (by either side) or any capture in the last 12 plies, with stalemate, or if S has a passed pawn on its 6th/7th at the end. Needs the result. | 20 | 0.3 + 0.08·deficit + length/100 (max 0.3) |
| 27 | `oppositeColoredBishops` | One bishop each, on opposite colors, no knights, and the same rooks and queens. Marked for both sides. | 16 | phase (1 bishops only, 0.75 with rooks, 0.5 with queens) × (0.5 + length/60) |

## Measurements

Corpus: the first 100,000 games of Lumbras Gigabase OTB 2025 (99,998 replayed; 2 have SAN that fischer-core does not resolve), 85.1 plies per game on average. The moves are extracted once with fischer-core to a binary cache (`Tools/ThemesBench`, `extract`) and the detector is measured on that cache. Release build, one thread, thread CPU time (`CLOCK_THREAD_CPUTIME_ID`), best of 5 rounds, on a Mac heavily loaded by other processes.

### Time

| Themes | µs of CPU per game | ns per ply |
|---|--:|--:|
| All 23 (bitset only, what an indexer does) | **13.9** | 164 |
| Tactical only | 10.0 | 118 |
| Strategic only | 7.0 | 82 |
| All 23 with the list of hits (`report`) and writing a TSV | 17.7 | — |

Target: under 20 µs per game with every theme. 100,000 games take 1.4 s of CPU; the whole 492k-game file about 7 s on one thread. This does not include turning SAN into moves (an importer already does that).

### Frequency and precision

Frequency: % of games with the theme for White, Black or either. Precision: 20 random hits per theme checked by hand (the FEN after the marked ply and ±8 plies of moves), with no engine; "unclear" counts as half. The review was done by Claude agents reading the positions with the rules at hand, not by a human player. There were up to three rounds: after each one the rules were fixed with the failures found and a fresh sample was drawn. The "Round" column says which round the figure comes from (earlier rounds in brackets). After round 2 a few themes only got filters that remove cases flagged as failures and were not reviewed again.

| Theme | White | Black | Either | Mean strength | Precision | Round (earlier) |
|---|--:|--:|--:|--:|--:|---|
| sacrifice | 0.94 % | 0.75 % | 1.68 % | 0.55 | 88 % (17.5/20) | 3 (35 %, 70 %) |
| exchangeSacrifice | 1.24 % | 1.26 % | 2.45 % | 0.76 | 90 % (18/20) | 2 (68 %) |
| matingAttack | 6.11 % | 4.94 % | 11.05 % | 0.91 | 92 % (18.5/20) | 2 (70 %) |
| oppositeCastlingAttack | 2.71 % | 2.12 % | 3.85 % | 0.68 | 90 % (18/20) | 3 (95 %, 92 %) |
| pin | 1.81 % | 1.55 % | 3.33 % | 0.54 | 85 % (17/20) | 3 (78 %, 92 %) |
| fork | 5.78 % | 5.02 % | 10.49 % | 0.57 | 95 % (19/20) | 2 (95 %) |
| discoveredAttack | 2.36 % | 2.08 % | 4.40 % | 0.67 | 95 % (19/20) | 1 |
| promotionRace | 1.55 % | 1.55 % | 1.55 % | 0.78 | 92 % (18.5/20) | 3 (78 %, 80 %) |
| greekGift | 0.08 % | 0.01 % | 0.09 % | 0.87 | 95 % (19/20) | 2 (62 %) |
| backRankMate | 0.13 % | 0.12 % | 0.25 % | 1.00 | 100 % | 1 |
| smotheredMate | 0.02 % | 0.02 % | 0.03 % | 1.00 | 100 % | 1 |
| minorityAttack | 0.28 % | 0.26 % | 0.54 % | 0.84 | 97 % (19.5/20) | 2 (95 %) |
| isolatedQueenPawn | 2.15 % | 2.04 % | 4.19 % | 0.75 | 100 % | 3 (82 %, 82 %) |
| bishopPair | 10.44 % | 11.23 % | 21.67 % | 0.73 | 100 % | 1 |
| goodVsBadBishop | 0.53 % | 0.59 % | 1.12 % | 0.78 | 97 % (19.5/20) | 2 (88 %) |
| outpostKnight | 9.38 % | 8.60 % | 16.51 % | 0.60 | 97 % (19.5/20) | 2 (90 %) |
| openFile | 10.56 % | 8.59 % | 17.95 % | 0.86 | 95 % (19/20) | 2 (68 %) |
| seventhRank | 9.39 % | 8.93 % | 16.81 % | 0.80 | 100 % | 2 (95 %) |
| passedPawn | 21.87 % | 18.95 % | 34.14 % | 0.85 | 92 % (18.5/20) | 2 (90 %) |
| spaceAdvantage | 0.33 % | 0.07 % | 0.40 % | 0.71 | 97 % (19.5/20) | 2 (95 %) |
| kingWalk | 0.02 % | 0.01 % | 0.03 % | 0.74 | 90 % (18/20) | 2 (15 %) |
| fortress ⚠️ | 0.05 % | 0.03 % | 0.08 % | 0.75 | **62 %** (12.5/20) | 3 (35 %, 48 %) |
| oppositeColoredBishops | 3.51 % | 3.51 % | 3.51 % | 0.69 | 100 % | 2 (52 %) |

77 % of the games have at least one theme. `promotionRace` and `oppositeColoredBishops` are always marked for both sides.

What is still weak, with the reviewers' proposals:

- **fortress (62 %, experimental)**: without an engine it cannot tell a fortress (a fixed blockade) from a draw held by activity. Active rook endings, queen endings with many checks and endings with a passed-pawn counterattack still get through. Proposal: require in the final position that the weak side has no rook or queen, or that the stronger side's extra pawns are blocked or have not moved in the last 20 plies; widen the counterplay filter to a passed pawn on the 5th; reject ≥ 6 checks in the last 30 plies.
- **pin (85 %)**: a few "pins" of a rook against a rook (which can just be taken) and gains that come from another double attack. Proposal: measure the balance 4 plies after the capture against the one before the pinning move, and require the pinned piece to be worth more than the pinner when it moves along the same line.
- **sacrifice (88 %)**: what is left are oversights (a piece left en prise in a game that is still drawn or won). Without an engine, the proposal is to require a forcing follow-up (check, capture, attack on a bigger piece or on the king zone) within 4 plies.
- **oppositeCastlingAttack (90 %)**: central tactical pushes (…c4 hitting the queen) counted as a pawn storm. Proposal: don't count pushes that attack a piece worth ≥ 3, and require a push on the rook or knight file next to the king.
- `openFile`, `passedPawn`, `bishopPair`, `outpostKnight` and `seventhRank` show up in 17–34 % of the games: correct, but common. For search, sort by strength (like ChessBase's *Theme Strength*).

### Random games

In 100 random legal games (with no result), the intent themes (`greekGift`, `minorityAttack`, `spaceAdvantage`, back-rank and smothered mates) show up in ≤ 2 % of the games and `fortress` never does; `isolatedQueenPawn`, `goodVsBadBishop` and `kingWalk` in ≤ 10 %. `sacrifice` shows up a lot (47 %): random play leaves pieces en prise and, without a result, the rule cannot tell an oversight from a sacrifice. On real games with a result, the precision is the one in the table.

### Reproducing

```bash
cd Tools/ThemesBench
swift build -c release
.build/release/themes-bench extract <games.pgn> 100000 4 games-100k.bin
.build/release/themes-bench measure games-100k.bin hits.tsv 5
.build/release/themes-bench sample <games.pgn> hits.tsv fork 20 1
```

`sample` prints random hits of a theme with the marked plies, the FEN after them and the moves around them, without player names. Lumbras Gigabase is CC BY-NC, so neither the cache, the hits nor the samples are part of this repository.

## Tests

`swift test` (27 tests): one hand-made game per theme (hits and some negatives per theme), and 100 random legal games generated with fischer-core where the tests check that the replay ends in the same placement, that the legal-move check agrees, that mate themes only appear when fischer-core also sees mate, and that the structural themes rarely fire at random.

## License

MIT.

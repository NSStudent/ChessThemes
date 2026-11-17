// themes-bench: mide ChessThemes sobre un PGN grande.
//
//   themes-bench extract <pgn> <partidas> <hilos> <cache.bin>
//       Reproduce el PGN con fischer-core y guarda las jugadas (2 bytes por ply) con el
//       resultado y el desplazamiento de cada partida en el PGN.
//   themes-bench measure <cache.bin> <hits.tsv> [vueltas=3]
//       Pasa ChessThemes por todas las partidas en un hilo y mide tiempo de CPU del hilo.
//       Saca la frecuencia de cada tema y escribe los hits (índice, desplazamiento, tema, bando,
//       fuerza, plies) para sacar muestras.
//   themes-bench sample <pgn> <hits.tsv> <tema> <n> [semilla=1]
//       Imprime n partidas al azar con el tema: jugadas numeradas con las plies marcadas
//       y el tablero en la primera ply. Sin nombres de jugadores.

import ChessThemes
import FischerCore
import Foundation

// MARK: - Utilidades

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func threadCPUSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

func wallSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

/// Jugadas SAN de la línea principal (sin comentarios, variantes, NAG ni números).
func sanTokens(_ movetext: String) -> [Substring] {
    var tokens: [Substring] = []
    var depth = 0
    var inComment = false
    var inLineComment = false
    var start: String.Index?
    let text = movetext
    var i = text.startIndex
    func close(_ end: String.Index) {
        guard let s = start else { return }
        start = nil
        var token = text[s ..< end]
        if let first = token.first, first.isNumber {
            guard let dot = token.lastIndex(of: ".") else { return }
            token = token[token.index(after: dot)...]
        }
        while let last = token.last, "!?".contains(last) { token = token.dropLast() }
        if token.isEmpty || token == "*" || token.first == "$" { return }
        tokens.append(token)
    }
    while i < text.endIndex {
        let c = text[i]
        if inComment {
            if c == "}" { inComment = false }
        } else if inLineComment {
            if c == "\n" { inLineComment = false }
        } else if c == "{" {
            close(i); inComment = true
        } else if c == ";" {
            close(i); inLineComment = true
        } else if c == "(" {
            close(i); depth += 1
        } else if c == ")" {
            close(i); depth = max(0, depth - 1)
        } else if depth > 0 {
        } else if c.isWhitespace {
            close(i)
        } else if start == nil {
            start = i
        }
        i = text.index(after: i)
    }
    close(text.endIndex)
    return tokens
}

struct ParsedGame {
    var offset: Int64
    var result: ThemeGameResult
    var moves: [ThemeMove]
    var sans: [String]
    var fen: String?
}

func parse(_ chunk: PGNGameChunk, keepSAN: Bool = false) -> ParsedGame? {
    guard let basic = try? chunk.basicGame() else { return nil }
    let fen = basic.tags[.fen]
    var game: Game
    if let fen {
        guard let p = Position(fen: fen), let g = try? Game(position: p) else { return nil }
        game = g
    } else {
        game = Game()
    }
    var moves: [ThemeMove] = []
    var sans: [String] = []
    for token in sanTokens(basic.movetext) {
        guard let r = try? game.resolve(san: String(token)) else { return nil }
        guard (try? game.execute(uncheckedMove: r.move) { r.promotion ?? .queen }) != nil else { return nil }
        moves.append(ThemeMove(r))
        if keepSAN { sans.append(String(token)) }
    }
    return ParsedGame(offset: chunk.startByteOffset, result: ThemeGameResult(pgn: basic.tags[.result] ?? "*"),
                      moves: moves, sans: sans, fen: fen)
}

// MARK: - Caché binaria

// Por partida: UInt64 desplazamiento, UInt8 resultado, UInt8 0, UInt16 plies, plies × UInt16
// (origen 6 bits, destino 6 bits, coronación 3 bits). Las partidas con FEN se saltan.

func encode(_ g: ParsedGame, into data: inout Data) {
    var off = UInt64(g.offset).littleEndian
    withUnsafeBytes(of: &off) { data.append(contentsOf: $0) }
    data.append(g.result.rawValue)
    data.append(0)
    var count = UInt16(min(g.moves.count, 65535)).littleEndian
    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
    for m in g.moves.prefix(65535) {
        var v = (UInt16(m.from) | UInt16(m.to) << 6 | UInt16(m.promotion) << 12).littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

struct CachedGame {
    var offset: Int64
    var result: ThemeGameResult
    var start: Int
    var count: Int
}

func loadCache(_ path: String) -> (games: [CachedGame], moves: [ThemeMove]) {
    guard let data = FileManager.default.contents(atPath: path) else { fail("no puedo leer \(path)") }
    var games: [CachedGame] = []
    var moves: [ThemeMove] = []
    moves.reserveCapacity(data.count / 2)
    data.withUnsafeBytes { raw in
        var i = 0
        while i + 12 <= raw.count {
            let off = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian
            let res = ThemeGameResult(rawValue: raw[i + 8]) ?? .unknown
            let count = Int(raw.loadUnaligned(fromByteOffset: i + 10, as: UInt16.self).littleEndian)
            i += 12
            let start = moves.count
            for _ in 0 ..< count {
                let v = raw.loadUnaligned(fromByteOffset: i, as: UInt16.self).littleEndian
                moves.append(ThemeMove(from: UInt8(v & 63), to: UInt8((v >> 6) & 63), promotion: UInt8(v >> 12)))
                i += 2
            }
            games.append(CachedGame(offset: Int64(off), result: res, start: start, count: count))
        }
    }
    return (games, moves)
}

// MARK: - extract

func extract(_ args: [String]) {
    guard args.count >= 4 else { fail("extract <pgn> <partidas> <hilos> <cache.bin>") }
    let path = args[0], limit = Int(args[1]) ?? 100_000, threads = Int(args[2]) ?? 4, out = args[3]
    guard let handle = FileHandle(forReadingAtPath: path) else { fail("no puedo abrir \(path)") }
    var chunker = PGNByteChunker()
    var pending: [PGNGameChunk] = []
    var read = 0, ok = 0, bad = 0, withFEN = 0
    var output = Data()
    let t0 = wallSeconds()
    func flush() {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let lock = NSLock()
        var parts = [Data](repeating: Data(), count: threads)
        var okLocal = [Int](repeating: 0, count: threads), badLocal = okLocal, fenLocal = okLocal
        DispatchQueue.concurrentPerform(iterations: threads) { w in
            var d = Data()
            var o = 0, b = 0, f = 0
            var i = w
            // Orden estable: cada hilo toma i ≡ w (mod hilos) y luego se intercalan.
            var encoded: [(Int, Data)] = []
            while i < batch.count {
                if let g = parse(batch[i]) {
                    if g.fen != nil { f += 1 } else {
                        var one = Data(); encode(g, into: &one); encoded.append((i, one)); o += 1
                    }
                } else { b += 1 }
                i += threads
            }
            for (_, e) in encoded { d.append(e) }
            lock.lock(); parts[w] = d; okLocal[w] = o; badLocal[w] = b; fenLocal[w] = f; lock.unlock()
        }
        for p in parts { output.append(p) }
        ok += okLocal.reduce(0, +); bad += badLocal.reduce(0, +); withFEN += fenLocal.reduce(0, +)
    }
    reading: while read < limit {
        let data = handle.readData(ofLength: 4 << 20)
        let chunks = data.isEmpty ? chunker.finish() : chunker.consume(data)
        for c in chunks {
            pending.append(c); read += 1
            if pending.count >= 4000 { flush(); FileHandle.standardError.write("… \(read)\n".data(using: .utf8)!) }
            if read >= limit { break reading }
        }
        if data.isEmpty { break }
    }
    flush()
    FileManager.default.createFile(atPath: out, contents: output)
    print("leídas \(read) · reproducidas \(ok) · con FEN (saltadas) \(withFEN) · con error \(bad) · \(String(format: "%.1f", wallSeconds() - t0)) s · \(output.count / 1024) KB")
}

// MARK: - measure

func measure(_ args: [String]) {
    guard args.count >= 2 else { fail("measure <cache.bin> <hits.tsv> [vueltas]") }
    let (games, moves) = loadCache(args[0])
    let rounds = args.count > 2 ? Int(args[2]) ?? 3 : 3
    let plies = moves.count
    print("Partidas \(games.count) · plies \(plies) (media \(String(format: "%.1f", Double(plies) / Double(max(1, games.count)))))")

    let sets: [(String, ThemeSet)] = [
        ("todos", .all),
        ("tácticos", ThemeSet(themes: Theme.allCases.filter { $0.category == .tactical })),
        ("estratégicos", ThemeSet(themes: Theme.allCases.filter { $0.category == .strategic })),
    ]
    moves.withUnsafeBufferPointer { all in
        for (name, set) in sets {
            let scanner = ThemeScanner(themes: set)
            var bestCPU = Double.infinity, bestWall = Double.infinity
            var checksum: UInt64 = 0
            for _ in 0 ..< rounds {
                let c0 = threadCPUSeconds(), w0 = wallSeconds()
                for g in games {
                    let buf = UnsafeBufferPointer(rebasing: all[g.start ..< g.start + g.count])
                    if let s = try? scanner.themes(of: buf, result: g.result) { checksum &+= s.rawValue }
                }
                bestCPU = min(bestCPU, threadCPUSeconds() - c0)
                bestWall = min(bestWall, wallSeconds() - w0)
            }
            let us = bestCPU / Double(games.count) * 1e6
            print(String(format: "Tiempo (%@): %.2f µs de CPU por partida (%.0f ns por ply; reloj %.2f µs) · mejor de %d vueltas · suma %llu",
                         name, us, bestCPU / Double(plies) * 1e9, bestWall / Double(games.count) * 1e6, rounds, checksum % 1000))
        }
        // Con lista de hits (lo que hace falta para guardar fuerzas).
        let scanner = ThemeScanner()
        let c0 = threadCPUSeconds()
        var tsv = "game\toffset\ttheme\tside\tstrength\tplies\n"
        var white = [Int](repeating: 0, count: 32), black = white, any = white
        var strengthSum = [Double](repeating: 0, count: 64)
        var errors = 0
        var anyTheme = 0
        for (gi, g) in games.enumerated() {
            let buf = UnsafeBufferPointer(rebasing: all[g.start ..< g.start + g.count])
            guard let rep = try? scanner.report(of: buf, result: g.result) else { errors += 1; continue }
            if rep.themes.rawValue != 0 { anyTheme += 1 }
            var seen = Set<Theme>()
            for h in rep.hits {
                let t = Int(h.theme.rawValue)
                if h.side == .white { white[t] += 1 } else { black[t] += 1 }
                strengthSum[t + (h.side == .white ? 0 : 32)] += Double(h.strength)
                if seen.insert(h.theme).inserted { any[t] += 1 }
                tsv += "\(gi)\t\(g.offset)\t\(h.theme)\t\(h.side)\t\(String(format: "%.2f", h.strength))\t\(h.plies.map(String.init).joined(separator: ","))\n"
            }
        }
        let reportCPU = threadCPUSeconds() - c0
        print(String(format: "Con lista de hits y TSV: %.2f µs de CPU por partida · errores %d · partidas con algún tema %.1f %%",
                     reportCPU / Double(games.count) * 1e6, errors, 100 * Double(anyTheme) / Double(games.count)))
        print("\n| Tema | Bit | Blancas | Negras | Alguno | Fuerza media |")
        print("|---|--:|--:|--:|--:|--:|")
        func pct(_ x: Int) -> String { String(format: "%.2f %%", 100 * Double(x) / Double(games.count)) }
        for t in Theme.allCases {
            let i = Int(t.rawValue)
            let hits = white[i] + black[i]
            let mean = hits == 0 ? 0 : (strengthSum[i] + strengthSum[i + 32]) / Double(hits)
            print("| \(t) | \(i) | \(pct(white[i])) | \(pct(black[i])) | \(pct(any[i])) | \(String(format: "%.2f", mean)) |")
        }
        try? tsv.write(toFile: args[1], atomically: true, encoding: .utf8)
    }
}

// MARK: - sample

func sample(_ args: [String]) {
    guard args.count >= 4 else { fail("sample <pgn> <hits.tsv> <tema> <n> [semilla]") }
    let pgn = args[0], theme = args[2], n = Int(args[3]) ?? 20
    var seed = UInt64(args.count > 4 ? Int(args[4]) ?? 1 : 1)
    guard let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { fail("no puedo leer \(args[1])") }
    let rows = text.split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        .filter { $0.count >= 6 && $0[2] == theme }
    guard !rows.isEmpty else { fail("sin hits de \(theme)") }
    func next() -> UInt64 {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    var picked: [Int] = []
    var pool = Array(rows.indices)
    while picked.count < min(n, rows.count) {
        let j = Int(next() % UInt64(pool.count))
        picked.append(pool.remove(at: j))
    }
    guard let handle = FileHandle(forReadingAtPath: pgn) else { fail("no puedo abrir \(pgn)") }
    print("\(theme): \(rows.count) hits; muestra de \(picked.count)\n")
    for (si, ri) in picked.enumerated() {
        let row = rows[ri]
        let offset = UInt64(row[1])!
        try? handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: 64 << 10)
        var chunker = PGNByteChunker(startOffset: Int64(offset))
        guard let chunk = (chunker.consume(data) + chunker.finish()).first, let g = parse(chunk, keepSAN: true) else {
            print("#\(si + 1) no se pudo releer"); continue
        }
        let plies = row[5].split(separator: ",").compactMap { Int($0) }
        let marks = Set(plies)
        var line = ""
        let lo = max(1, (plies.min() ?? 1) - 8), hi = min(g.sans.count, (plies.max() ?? 1) + 8)
        if lo > 1 { line += "… " }
        for (i, san) in g.sans.enumerated() where i + 1 >= lo && i + 1 <= hi {
            let ply = i + 1
            if i % 2 == 0 { line += "\(i / 2 + 1)." } else if ply == lo { line += "\(i / 2 + 1)..." }
            line += marks.contains(ply) ? "[\(san)]" : san
            line += " "
        }
        if hi < g.sans.count { line += "…" }
        print("#\(si + 1) juego \(row[0]) · bando \(row[3]) · fuerza \(row[4]) · plies \(row[5]) · resultado \(g.result) · \(g.sans.count) plies")
        // FEN tras la primera y la última ply marcadas.
        for p in Set([plies.first ?? 0, plies.last ?? 0]).sorted() where p >= 1 && p <= g.moves.count {
            var game = Game()
            for san in g.sans.prefix(p) {
                if let r = try? game.resolve(san: san) { try? game.execute(uncheckedMove: r.move) { r.promotion ?? .queen } }
            }
            print("  FEN tras ply \(p): \(game.position.fen())")
        }
        print(line)
        print("")
    }
}

// MARK: - main

let argv = CommandLine.arguments
guard argv.count >= 2 else { fail("themes-bench extract|measure|sample …") }
switch argv[1] {
case "extract": extract(Array(argv.dropFirst(2)))
case "measure": measure(Array(argv.dropFirst(2)))
case "sample": sample(Array(argv.dropFirst(2)))
default: fail("orden desconocida \(argv[1])")
}

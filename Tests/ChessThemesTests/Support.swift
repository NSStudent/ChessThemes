import FischerCore
@testable import ChessThemes

/// Jugadas SAN (con o sin números) a `[ResolvedMove]` con fischer-core.
func resolved(_ san: String, fen: String? = nil) throws -> [ResolvedMove] {
    var game: Game
    if let fen {
        guard let position = Position(fen: fen) else { throw FixtureError.badFEN(fen) }
        game = try Game(position: position)
    } else {
        game = Game()
    }
    var out: [ResolvedMove] = []
    for raw in san.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        var token = Substring(raw)
        if let first = token.first, first.isNumber {
            guard let dot = token.lastIndex(of: ".") else { continue }
            token = token[token.index(after: dot)...]
        }
        if token.isEmpty { continue }
        do {
            let r = try game.resolve(san: String(token))
            try game.execute(uncheckedMove: r.move) { r.promotion ?? .queen }
            out.append(r)
        } catch {
            throw FixtureError.badMove(String(token), out.count)
        }
    }
    return out
}

enum FixtureError: Error {
    case badFEN(String)
    case badMove(String, Int)
}

func report(_ san: String, fen: String? = nil, result: ThemeGameResult = .unknown) throws -> ThemeReport {
    let moves = try resolved(san, fen: fen)
    return try ThemeScanner().report(of: moves, startFEN: fen, result: result)
}

/// Repite una vuelta de jugadas tranquilas (para sostener un tramo estratégico).
func shuffle(_ cycle: String, times: Int) -> String {
    Array(repeating: cycle, count: times).joined(separator: " ")
}

/// Generador reproducible para las partidas aleatorias.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

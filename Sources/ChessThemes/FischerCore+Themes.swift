// Entrada con tipos de fischer-core: `[ResolvedMove]` y FEN opcional.

import FischerCore

extension ThemeMove {
    public init(_ resolved: ResolvedMove) {
        let p: UInt8
        switch resolved.promotion {
        case .knight?: p = 1
        case .bishop?: p = 2
        case .rook?: p = 3
        case .queen?: p = 4
        case nil: p = 0
        }
        self.init(from: UInt8(resolved.move.start.rawValue), to: UInt8(resolved.move.end.rawValue), promotion: p)
    }
}

extension ThemeScanner {
    /// Bitset de temas de una partida de fischer-core.
    public func themes(of moves: [ResolvedMove], startFEN: String? = nil, result: ThemeGameResult = .unknown) throws(ThemeError) -> ThemeSet {
        try themes(of: moves.map(ThemeMove.init), startFEN: startFEN, result: result)
    }

    /// Temas con fuerza y plies de una partida de fischer-core.
    public func report(of moves: [ResolvedMove], startFEN: String? = nil, result: ThemeGameResult = .unknown) throws(ThemeError) -> ThemeReport {
        try report(of: moves.map(ThemeMove.init), startFEN: startFEN, result: result)
    }
}

/// Atajos sin escáner propio. Para muchas partidas, crea un `ThemeScanner` por hilo y reúsalo.
public enum ChessThemes {
    public static func detect(_ moves: [ResolvedMove], startFEN: String? = nil, result: ThemeGameResult = .unknown) throws(ThemeError) -> ThemeReport {
        try ThemeScanner().report(of: moves, startFEN: startFEN, result: result)
    }

    public static func detect(_ moves: [ThemeMove], startFEN: String? = nil, result: ThemeGameResult = .unknown) throws(ThemeError) -> ThemeReport {
        try ThemeScanner().report(of: moves, startFEN: startFEN, result: result)
    }
}

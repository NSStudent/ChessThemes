// Catálogo de temas y tipos del resultado.
//
// Los números de `Theme` son el formato del índice (`themesVisited`): no se renumeran.
// 0–15 son temas tácticos y 16–31 estratégicos. Los huecos (11–15, 28–31) quedan libres.

/// Bando que «tiene» el tema: el que sacrifica, ataca, clava, tiene el alfil bueno…
public enum ThemeSide: UInt8, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case white = 0
    case black = 1

    public var opponent: ThemeSide { self == .white ? .black : .white }
    public var description: String { self == .white ? "white" : "black" }
}

/// Resultado de la partida. Afina algunos temas (fortaleza, ataque de mate sin mate en el tablero)
/// y suma a la fuerza cuando el bando del tema gana.
public enum ThemeGameResult: UInt8, Sendable, Hashable {
    case whiteWins
    case blackWins
    case draw
    case unknown

    /// Lee la etiqueta `Result` del PGN (`1-0`, `0-1`, `1/2-1/2`, `*`).
    public init(pgn: String) {
        switch pgn {
        case "1-0": self = .whiteWins
        case "0-1": self = .blackWins
        case "1/2-1/2", "½-½": self = .draw
        default: self = .unknown
        }
    }
}

public enum ThemeCategory: String, Sendable, Hashable {
    case tactical
    case strategic
}

/// Temas detectados. El valor es el bit del índice (más 32 si el tema es de las negras).
public enum Theme: UInt8, CaseIterable, Sendable, Hashable, CustomStringConvertible {
    // MARK: Tácticos (0–15)
    /// Se entrega al menos una pieza menor (2 peones de material neto) y no se recupera enseguida.
    case sacrifice = 0
    /// Torre por pieza menor entregada a propósito.
    case exchangeSacrifice = 1
    /// Mate en el tablero o ataque al rey que decide la partida.
    case matingAttack = 2
    /// Enroques opuestos y avalancha de peones contra el rey enemigo.
    case oppositeCastlingAttack = 3
    /// Clavada (contra el rey o la dama) que gana material.
    case pin = 4
    /// Doble ataque de una pieza que gana material.
    case fork = 5
    /// Ataque (o jaque) a la descubierta que gana material o da mate.
    case discoveredAttack = 6
    /// Los dos bandos corren con peones pasados a la vez.
    case promotionRace = 7
    /// Sacrificio griego: Axh7+ (Axh2+) con el rey enrocado corto y Cg5 o Dh5 detrás.
    case greekGift = 8
    /// Mate del pasillo.
    case backRankMate = 9
    /// Mate de la coz.
    case smotheredMate = 10

    // MARK: Estratégicos (16–31)
    /// Ataque de minoría: el bando con menos peones en a–c empuja el peón b.
    case minorityAttack = 16
    /// Peón de dama aislado en el medio juego.
    case isolatedQueenPawn = 17
    /// Pareja de alfiles contra alfil y caballo o dos caballos.
    case bishopPair = 18
    /// Alfil bueno contra alfil malo.
    case goodVsBadBishop = 19
    /// Caballo en un puesto avanzado (apoyado por un peón, sin peones rivales que lo echen).
    case outpostKnight = 20
    /// Dominio de una columna abierta con torre.
    case openFile = 21
    /// Torre (o torres) en séptima.
    case seventhRank = 22
    /// Peón pasado que llega a sexta o más.
    case passedPawn = 23
    /// Ventaja de espacio: peones centrales en quinta con el centro trabado.
    case spaceAdvantage = 24
    /// Paseo del rey con damas en el tablero.
    case kingWalk = 25
    /// Tablas con material de menos: fortaleza o defensa que aguanta.
    case fortress = 26
    /// Alfiles de distinto color.
    case oppositeColoredBishops = 27

    public var category: ThemeCategory { rawValue < 16 ? .tactical : .strategic }

    /// Nombre en inglés, estable (sirve de clave en JSON y en MCP).
    public var description: String {
        switch self {
        case .sacrifice: "sacrifice"
        case .exchangeSacrifice: "exchangeSacrifice"
        case .matingAttack: "matingAttack"
        case .oppositeCastlingAttack: "oppositeCastlingAttack"
        case .pin: "pin"
        case .fork: "fork"
        case .discoveredAttack: "discoveredAttack"
        case .promotionRace: "promotionRace"
        case .greekGift: "greekGift"
        case .backRankMate: "backRankMate"
        case .smotheredMate: "smotheredMate"
        case .minorityAttack: "minorityAttack"
        case .isolatedQueenPawn: "isolatedQueenPawn"
        case .bishopPair: "bishopPair"
        case .goodVsBadBishop: "goodVsBadBishop"
        case .outpostKnight: "outpostKnight"
        case .openFile: "openFile"
        case .seventhRank: "seventhRank"
        case .passedPawn: "passedPawn"
        case .spaceAdvantage: "spaceAdvantage"
        case .kingWalk: "kingWalk"
        case .fortress: "fortress"
        case .oppositeColoredBishops: "oppositeColoredBishops"
        }
    }

    /// Nombre en español para la interfaz.
    public var spanishName: String {
        switch self {
        case .sacrifice: "Sacrificio"
        case .exchangeSacrifice: "Sacrificio de calidad"
        case .matingAttack: "Ataque de mate"
        case .oppositeCastlingAttack: "Ataque con enroques opuestos"
        case .pin: "Clavada"
        case .fork: "Doble ataque"
        case .discoveredAttack: "Ataque a la descubierta"
        case .promotionRace: "Carrera de peones"
        case .greekGift: "Sacrificio griego"
        case .backRankMate: "Mate del pasillo"
        case .smotheredMate: "Mate de la coz"
        case .minorityAttack: "Ataque de minoría"
        case .isolatedQueenPawn: "Peón de dama aislado"
        case .bishopPair: "Pareja de alfiles"
        case .goodVsBadBishop: "Alfil bueno contra alfil malo"
        case .outpostKnight: "Caballo en puesto avanzado"
        case .openFile: "Columna abierta"
        case .seventhRank: "Torre en séptima"
        case .passedPawn: "Peón pasado"
        case .spaceAdvantage: "Ventaja de espacio"
        case .kingWalk: "Paseo del rey"
        case .fortress: "Fortaleza"
        case .oppositeColoredBishops: "Alfiles de distinto color"
        }
    }

    /// Bit del índice para este tema y bando.
    @inlinable
    public func bit(for side: ThemeSide) -> UInt64 {
        1 &<< (UInt64(rawValue) &+ (side == .white ? 0 : 32))
    }
}

/// Bitset de temas por bando: bits 0–31 blancas, 32–63 negras. Es `themesVisited` en la firma.
public struct ThemeSet: OptionSet, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public init(_ theme: Theme, side: ThemeSide) { rawValue = theme.bit(for: side) }

    /// El tema para los dos bandos.
    public init(_ theme: Theme) { rawValue = theme.bit(for: .white) | theme.bit(for: .black) }

    public init<S: Sequence>(themes: S) where S.Element == Theme {
        rawValue = 0
        for t in themes { rawValue |= t.bit(for: .white) | t.bit(for: .black) }
    }

    /// Todos los temas del catálogo, los dos bandos.
    public static let all = ThemeSet(themes: Theme.allCases)

    public func contains(_ theme: Theme, side: ThemeSide) -> Bool { rawValue & theme.bit(for: side) != 0 }
    /// El tema aparece para alguno de los dos bandos.
    public func contains(_ theme: Theme) -> Bool { rawValue & (theme.bit(for: .white) | theme.bit(for: .black)) != 0 }

    /// Junta los dos bandos en los bits 0–31 («tema en la partida, del bando que sea»).
    public var ignoringSides: UInt32 { UInt32(truncatingIfNeeded: rawValue) | UInt32(truncatingIfNeeded: rawValue >> 32) }

    /// Temas presentes (cualquiera de los bandos), en el orden del catálogo.
    public var themes: [Theme] { Theme.allCases.filter { contains($0) } }
}

/// Un tema encontrado en una partida.
public struct ThemeHit: Sendable, Hashable, CustomStringConvertible {
    public let theme: Theme
    public let side: ThemeSide
    /// De 0 a 1. Para ordenar como la «Theme Strength» de ChessBase 18.
    public let strength: Float
    /// Plies (1 = primera jugada de la lista) donde se ve el tema; como mucho cuatro.
    public let plies: [Int]
    /// Veces que se detectó (tácticos) o 1 (estratégicos: el tramo más largo).
    public let occurrences: Int

    public init(theme: Theme, side: ThemeSide, strength: Float, plies: [Int], occurrences: Int) {
        self.theme = theme
        self.side = side
        self.strength = strength
        self.plies = plies
        self.occurrences = occurrences
    }

    public var description: String {
        "\(theme)(\(side), \(String(format: "%.2f", strength)), plies \(plies))"
    }
}

/// Lo que devuelve el detector para una partida.
public struct ThemeReport: Sendable, Hashable {
    public let hits: [ThemeHit]
    public let themes: ThemeSet

    public init(hits: [ThemeHit], themes: ThemeSet) {
        self.hits = hits
        self.themes = themes
    }

    public func hit(_ theme: Theme, side: ThemeSide) -> ThemeHit? {
        hits.first { $0.theme == theme && $0.side == side }
    }

    /// La fuerza más alta del tema (cualquiera de los bandos), o 0.
    public func strength(of theme: Theme) -> Float {
        hits.lazy.filter { $0.theme == theme }.map(\.strength).max() ?? 0
    }

    /// Fuerzas cuantizadas a 4 bits por tema (0–15), 23 temas × 2 bandos en 23 bytes:
    /// lo que haría falta guardar en el índice para ordenar sin reproducir.
    public func quantizedStrength(_ theme: Theme, side: ThemeSide) -> UInt8 {
        guard let h = hit(theme, side: side) else { return 0 }
        return UInt8(max(1, min(15, (h.strength * 15).rounded())))
    }
}

/// Una jugada en formato neutro: casillas 0–63 (a1 = 0, h8 = 63) y coronación
/// (0 nada, 1 caballo, 2 alfil, 3 torre, 4 dama). El enroque es el rey moviéndose dos columnas.
public struct ThemeMove: Sendable, Hashable {
    public var from: UInt8
    public var to: UInt8
    public var promotion: UInt8

    public init(from: UInt8, to: UInt8, promotion: UInt8 = 0) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    /// Lee UCI (`e2e4`, `e7e8q`).
    public init?(uci: String) {
        let c = Array(uci.utf8)
        guard c.count == 4 || c.count == 5 else { return nil }
        func sq(_ f: UInt8, _ r: UInt8) -> UInt8? {
            guard (97...104).contains(f), (49...56).contains(r) else { return nil }
            return (r - 49) * 8 + (f - 97)
        }
        guard let a = sq(c[0], c[1]), let b = sq(c[2], c[3]) else { return nil }
        var p: UInt8 = 0
        if c.count == 5 {
            switch c[4] {
            case UInt8(ascii: "n"): p = 1
            case UInt8(ascii: "b"): p = 2
            case UInt8(ascii: "r"): p = 3
            case UInt8(ascii: "q"): p = 4
            default: return nil
            }
        }
        self.init(from: a, to: b, promotion: p)
    }
}

public enum ThemeError: Error, Equatable, Sendable {
    case invalidFEN
    /// La jugada en esa posición (índice desde 0) no tiene pieza del bando que mueve en el origen.
    case illegalMove(index: Int)
}

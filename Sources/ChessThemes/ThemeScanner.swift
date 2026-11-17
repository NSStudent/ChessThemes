// Detector de temas. Una pasada por la partida con un tablero de bitboards propio
// (6 por tipo + 2 por color) y búferes por ply reutilizados entre partidas.
//
// Tácticos: se apuntan candidatos durante la pasada (doble ataque, clavada, descubierta…)
// y al final se confirman mirando el material «asentado» (después de la cadena de capturas):
// un doble ataque cuenta si gana al menos 2 peones de material.
// Estratégicos: condiciones por posición con tramos (runs) de plies seguidas.

// Tipos: 0 peón, 1 caballo, 2 alfil, 3 torre, 4 dama, 5 rey. Colores: 0 blancas, 1 negras.
private let PAWN = 0, KNIGHT = 1, BISHOP = 2, ROOK = 3, QUEEN = 4, KING = 5
private let NONE: UInt8 = 0xFF
private let pieceValue: [Int16] = [1, 3, 3, 5, 9, 0]

@inline(__always) private func value(_ t: Int) -> Int {
    switch t {
    case 0: 1
    case 1, 2: 3
    case 3: 5
    case 4: 9
    default: 100
    }
}

/// Rango relativo 0–7 (0 = primera fila del bando).
@inline(__always) private func relRank(_ sq: Int, _ side: Int) -> Int { side == 0 ? sq >> 3 : 7 - (sq >> 3) }

private struct Run {
    var start: Int32 = -1
    var bestLen: Int32 = 0
    var bestStart: Int32 = 0
    /// Extra del tramo en curso y del tramo más largo (el que se informa).
    var current: Float = 0
    var extra: Float = 0
}

private struct Candidate {
    var ply: Int32
    var mask: UInt64
    var square: Int8 = -1
    var flag: Bool = false
}

/// Detector reutilizable. No es `Sendable`: usa uno por hilo.
public final class ThemeScanner {
    /// Temas que se buscan (los dos bandos). Por defecto, todos.
    public let enabled: ThemeSet

    private let rays: UnsafeMutablePointer<UInt64>
    private let knightT: UnsafeMutablePointer<UInt64>
    private let kingT: UnsafeMutablePointer<UInt64>
    private let pawnT: UnsafeMutablePointer<UInt64>

    // 0–5 tipos, 6 blancas, 7 negras.
    private let bb: UnsafeMutablePointer<UInt64>

    // Búferes por índice de posición (0 = inicial, k = tras la jugada k).
    private var capacity = 0
    private var bal: UnsafeMutablePointer<Int16>
    private var capt: UnsafeMutablePointer<UInt8>
    private var mvType: UnsafeMutablePointer<UInt8>
    private var fromSq: UnsafeMutablePointer<UInt8>
    private var toSq: UnsafeMutablePointer<UInt8>
    private var checks: UnsafeMutablePointer<UInt8>
    private var counts: UnsafeMutablePointer<UInt32>
    private var pinAt: UnsafeMutablePointer<UInt64>
    /// Bit 0: la pieza movida estaba en prise. Bit 1: la menor capturada atacaba rey o dama. Bit 2: la pieza movida estaba atacada.
    private var flags: UnsafeMutablePointer<UInt8>

    // Acumulador de hits por bit (tema + 32 × bando).
    private let best: UnsafeMutablePointer<Float>
    private let occurrences: UnsafeMutablePointer<Int32>
    private let hitPlies: UnsafeMutablePointer<Int32>
    private let hitPlyCount: UnsafeMutablePointer<UInt8>
    private let runs: UnsafeMutablePointer<Run>

    private var forks: [Candidate] = []
    private var pins: [Candidate] = []
    private var discovered: [Candidate] = []
    private var greek: [Candidate] = []
    private var minority: [Candidate] = []

    private var n = 0
    private var startSide = 0
    private var result: ThemeGameResult = .unknown
    private var epSquare = -1
    private var found: UInt64 = 0

    // Estado por partida.
    private var pinnedBy: (UInt64, UInt64) = (0, 0)
    private var castled: (Int, Int) = (0, 0) // 0 no, 1 corto, 2 largo
    private var storm: (Int, Int) = (0, 0)
    private var stormPlies: (Int32, Int32) = (0, 0)
    /// Por bando: última ply de empuje, empujes del tramo en curso, ply en que empezó.
    private var stormStreak: [Int32] = [Int32](repeating: 0, count: 6)
    private var walkCount: (Int, Int) = (0, 0)
    private var walkRank: (Int, Int) = (0, 0)
    private var walkPly: (Int32, Int32) = (0, 0)
    private var raceEvents: [Candidate] = []
    private var anyPromotion = false
    private var passedPromoted: (Bool, Bool) = (false, false)

    // Interruptores derivados de `enabled`.
    private let wantFork, wantPin, wantDiscovered, wantSacrifice, wantExchange, wantMate, wantOpposite,
                wantRace, wantGreek, wantBackRank, wantSmothered, wantMinority, wantStrategic, wantKingWalk,
                wantFortress: Bool

    public init(themes: ThemeSet = .all) {
        enabled = themes
        let t = Tables.shared
        rays = t.rays; knightT = t.knight; kingT = t.king; pawnT = t.pawnAttacks
        bb = .allocate(capacity: 8)
        bal = .allocate(capacity: 1); capt = .allocate(capacity: 1); mvType = .allocate(capacity: 1)
        fromSq = .allocate(capacity: 1); toSq = .allocate(capacity: 1); checks = .allocate(capacity: 1)
        counts = .allocate(capacity: 1); pinAt = .allocate(capacity: 1); flags = .allocate(capacity: 1)
        best = .allocate(capacity: 64)
        occurrences = .allocate(capacity: 64)
        hitPlies = .allocate(capacity: 64 * 4)
        hitPlyCount = .allocate(capacity: 64)
        runs = .allocate(capacity: 64)
        forks.reserveCapacity(16); pins.reserveCapacity(16); discovered.reserveCapacity(16)
        func on(_ th: Theme) -> Bool { themes.contains(th) }
        wantFork = on(.fork); wantPin = on(.pin); wantDiscovered = on(.discoveredAttack)
        wantSacrifice = on(.sacrifice); wantExchange = on(.exchangeSacrifice); wantMate = on(.matingAttack)
        wantOpposite = on(.oppositeCastlingAttack); wantRace = on(.promotionRace); wantGreek = on(.greekGift)
        wantBackRank = on(.backRankMate); wantSmothered = on(.smotheredMate); wantMinority = on(.minorityAttack)
        wantKingWalk = on(.kingWalk); wantFortress = on(.fortress)
        wantStrategic = [.isolatedQueenPawn, .bishopPair, .goodVsBadBishop, .outpostKnight, .openFile,
                         .seventhRank, .passedPawn, .spaceAdvantage, .oppositeColoredBishops].contains { on($0) }
        reserve(256)
    }

    deinit {
        bb.deallocate()
        bal.deallocate(); capt.deallocate(); mvType.deallocate(); fromSq.deallocate(); toSq.deallocate()
        checks.deallocate(); counts.deallocate(); pinAt.deallocate(); flags.deallocate()
        best.deallocate(); occurrences.deallocate(); hitPlies.deallocate(); hitPlyCount.deallocate(); runs.deallocate()
    }

    private func reserve(_ plies: Int) {
        guard plies + 1 > capacity else { return }
        let c = max(plies + 1, capacity * 2)
        bal.deallocate(); capt.deallocate(); mvType.deallocate(); fromSq.deallocate(); toSq.deallocate()
        checks.deallocate(); counts.deallocate(); pinAt.deallocate(); flags.deallocate()
        bal = .allocate(capacity: c); capt = .allocate(capacity: c); mvType = .allocate(capacity: c)
        fromSq = .allocate(capacity: c); toSq = .allocate(capacity: c); checks = .allocate(capacity: c)
        counts = .allocate(capacity: c); pinAt = .allocate(capacity: c); flags = .allocate(capacity: c)
        capacity = c
    }

    // MARK: - API

    /// Solo el bitset (sin construir la lista de hits). Es lo que va en `themesVisited`.
    public func themes(of moves: [ThemeMove], startFEN: String? = nil, result: ThemeGameResult = .unknown) throws(ThemeError) -> ThemeSet {
        try moves.withUnsafeBufferPointer { (buf) throws(ThemeError) in try run(buf, startFEN: startFEN, result: result) }
        return ThemeSet(rawValue: found)
    }

    /// Temas con fuerza y plies.
    public func report(of moves: [ThemeMove], startFEN: String? = nil, result: ThemeGameResult = .unknown) throws(ThemeError) -> ThemeReport {
        try moves.withUnsafeBufferPointer { (buf) throws(ThemeError) in try run(buf, startFEN: startFEN, result: result) }
        return buildReport()
    }

    /// Variante sin copias para el índice: jugadas en un búfer propio.
    public func themes(of moves: UnsafeBufferPointer<ThemeMove>, startFEN: String? = nil, result: ThemeGameResult = .unknown) throws(ThemeError) -> ThemeSet {
        try run(moves, startFEN: startFEN, result: result)
        return ThemeSet(rawValue: found)
    }

    public func report(of moves: UnsafeBufferPointer<ThemeMove>, startFEN: String? = nil, result: ThemeGameResult = .unknown) throws(ThemeError) -> ThemeReport {
        try run(moves, startFEN: startFEN, result: result)
        return buildReport()
    }

    private func buildReport() -> ThemeReport {
        var hits: [ThemeHit] = []
        var bits = found
        while bits != 0 {
            let i = lsb(bits); bits &= bits - 1
            guard let theme = Theme(rawValue: UInt8(i & 31)) else { continue }
            let pc = Int(hitPlyCount[i])
            var plies: [Int] = []
            plies.reserveCapacity(pc)
            for j in 0 ..< pc { plies.append(Int(hitPlies[i * 4 + j])) }
            hits.append(ThemeHit(theme: theme, side: i < 32 ? .white : .black, strength: min(1, best[i]),
                                 plies: plies, occurrences: Int(occurrences[i])))
        }
        hits.sort { ($0.theme.rawValue, $0.side.rawValue) < ($1.theme.rawValue, $1.side.rawValue) }
        return ThemeReport(hits: hits, themes: ThemeSet(rawValue: found))
    }

    /// Colocación FEN de la última posición reproducida (para tests).
    func debugPlacement() -> String {
        var s = ""
        for r in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for f in 0 ..< 8 {
                let b = bit(r * 8 + f)
                guard (bb[6] | bb[7]) & b != 0 else { empty += 1; continue }
                if empty > 0 { s += String(empty); empty = 0 }
                let c = Array("pnbrqk")[typeAt(b)]
                s.append(bb[6] & b != 0 ? Character(c.uppercased()) : c)
            }
            if empty > 0 { s += String(empty) }
            if r > 0 { s += "/" }
        }
        return s
    }

    /// ¿Tiene jugadas legales el bando al que le toca en la última posición?
    func debugSideToMoveHasLegalMove() -> Bool { hasLegalMove(n == 0 ? startSide : sideOf(n) ^ 1) }

    // MARK: - Pasada

    private func run(_ moves: UnsafeBufferPointer<ThemeMove>, startFEN: String?, result: ThemeGameResult) throws(ThemeError) {
        reserve(moves.count)
        self.result = result
        resetGame()
        try setUp(startFEN)
        n = moves.count
        bal[0] = materialBalance()
        counts[0] = packedCounts()
        capt[0] = NONE; checks[0] = 0; mvType[0] = NONE; flags[0] = 0; pinAt[0] = 0
        for k in 1 ... max(1, n) where k <= n {
            try apply(moves[k - 1], k: k)
        }
        finish()
    }

    private func resetGame() {
        found = 0
        for i in 0 ..< 64 {
            best[i] = 0; occurrences[i] = 0; hitPlyCount[i] = 0; runs[i] = Run()
        }
        forks.removeAll(keepingCapacity: true); pins.removeAll(keepingCapacity: true)
        discovered.removeAll(keepingCapacity: true); greek.removeAll(keepingCapacity: true)
        minority.removeAll(keepingCapacity: true)
        pinnedBy = (0, 0); castled = (0, 0); storm = (0, 0); stormPlies = (0, 0)
        for i in 0 ..< 6 { stormStreak[i] = 0 }
        walkCount = (0, 0); walkRank = (0, 0); walkPly = (0, 0)
        raceEvents.removeAll(keepingCapacity: true); anyPromotion = false; passedPromoted = (false, false)
        epSquare = -1
    }

    private func setUp(_ fen: String?) throws(ThemeError) {
        for i in 0 ..< 8 { bb[i] = 0 }
        guard let fen, !fen.isEmpty else {
            bb[PAWN] = 0x00FF_0000_0000_FF00
            bb[KNIGHT] = 0x4200_0000_0000_0042
            bb[BISHOP] = 0x2400_0000_0000_0024
            bb[ROOK] = 0x8100_0000_0000_0081
            bb[QUEEN] = 0x0800_0000_0000_0008
            bb[KING] = 0x1000_0000_0000_0010
            bb[6] = 0xFFFF
            bb[7] = 0xFFFF_0000_0000_0000
            startSide = 0
            return
        }
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard let placement = fields.first else { throw .invalidFEN }
        var rank = 7, file = 0
        for ch in placement.utf8 {
            if ch == UInt8(ascii: "/") {
                guard file == 8 else { throw .invalidFEN }
                rank -= 1; file = 0
                guard rank >= 0 else { throw .invalidFEN }
                continue
            }
            if ch >= 49 && ch <= 56 { file += Int(ch - 48); guard file <= 8 else { throw .invalidFEN }; continue }
            guard file < 8 else { throw .invalidFEN }
            let isWhite = ch < 97
            let t: Int
            switch ch | 0x20 {
            case UInt8(ascii: "p"): t = PAWN
            case UInt8(ascii: "n"): t = KNIGHT
            case UInt8(ascii: "b"): t = BISHOP
            case UInt8(ascii: "r"): t = ROOK
            case UInt8(ascii: "q"): t = QUEEN
            case UInt8(ascii: "k"): t = KING
            default: throw .invalidFEN
            }
            let sq = bit(rank * 8 + file)
            bb[t] |= sq
            bb[isWhite ? 6 : 7] |= sq
            file += 1
        }
        guard rank == 0, file == 8 else { throw .invalidFEN }
        guard popcount(bb[KING] & bb[6]) == 1, popcount(bb[KING] & bb[7]) == 1 else { throw .invalidFEN }
        startSide = fields.count > 1 && fields[1] == "b" ? 1 : 0
        if fields.count > 3, fields[3] != "-", let ep = ThemeMove(uci: String(fields[3]) + "a1") {
            epSquare = Int(ep.from)
        }
    }

    // MARK: - Utilidades de tablero

    @inline(__always) private func ray(_ dir: Int, _ sq: Int, _ occ: UInt64) -> UInt64 {
        let r = rays[dir &* 64 &+ sq]
        let b = r & occ
        if b == 0 { return r }
        let f = dir < 4 ? lsb(b) : msb(b)
        return r ^ rays[dir &* 64 &+ f]
    }

    @inline(__always) private func firstBlocker(_ dir: Int, _ sq: Int, _ occ: UInt64) -> Int {
        let b = rays[dir &* 64 &+ sq] & occ
        if b == 0 { return -1 }
        return dir < 4 ? lsb(b) : msb(b)
    }

    @inline(__always) private func bishopAttacks(_ sq: Int, _ occ: UInt64) -> UInt64 {
        ray(1, sq, occ) | ray(3, sq, occ) | ray(5, sq, occ) | ray(7, sq, occ)
    }

    @inline(__always) private func rookAttacks(_ sq: Int, _ occ: UInt64) -> UInt64 {
        ray(0, sq, occ) | ray(2, sq, occ) | ray(4, sq, occ) | ray(6, sq, occ)
    }

    @inline(__always) private func attacks(_ type: Int, _ side: Int, _ sq: Int, _ occ: UInt64) -> UInt64 {
        switch type {
        case PAWN: pawnT[side &* 64 &+ sq]
        case KNIGHT: knightT[sq]
        case BISHOP: bishopAttacks(sq, occ)
        case ROOK: rookAttacks(sq, occ)
        case QUEEN: bishopAttacks(sq, occ) | rookAttacks(sq, occ)
        default: kingT[sq]
        }
    }

    /// Piezas de los dos colores que atacan sq.
    @inline(__always) private func attackersTo(_ sq: Int, _ occ: UInt64) -> UInt64 {
        (pawnT[sq] & bb[PAWN] & bb[7]) | (pawnT[64 &+ sq] & bb[PAWN] & bb[6])
            | (knightT[sq] & bb[KNIGHT]) | (kingT[sq] & bb[KING])
            | (bishopAttacks(sq, occ) & (bb[BISHOP] | bb[QUEEN]))
            | (rookAttacks(sq, occ) & (bb[ROOK] | bb[QUEEN]))
    }

    @inline(__always) private func typeAt(_ sqBit: UInt64) -> Int {
        if bb[PAWN] & sqBit != 0 { return PAWN }
        if bb[KNIGHT] & sqBit != 0 { return KNIGHT }
        if bb[BISHOP] & sqBit != 0 { return BISHOP }
        if bb[ROOK] & sqBit != 0 { return ROOK }
        if bb[QUEEN] & sqBit != 0 { return QUEEN }
        return KING
    }

    private func materialBalance() -> Int16 {
        var s: Int16 = 0
        for t in 0 ..< 5 {
            s += pieceValue[t] * Int16(popcount(bb[t] & bb[6]) - popcount(bb[t] & bb[7]))
        }
        return s
    }

    /// Por bando, 4 bits cada uno: damas, torres, menores. Blancas en los bits 0–11, negras 12–23.
    @inline(__always) private func packedCounts() -> UInt32 {
        let w = bb[6], b = bb[7], minors = bb[KNIGHT] | bb[BISHOP]
        let pw = UInt32(min(15, popcount(bb[QUEEN] & w))) | UInt32(min(15, popcount(bb[ROOK] & w))) << 4
            | UInt32(min(15, popcount(minors & w))) << 8
        let pb = UInt32(min(15, popcount(bb[QUEEN] & b))) | UInt32(min(15, popcount(bb[ROOK] & b))) << 4
            | UInt32(min(15, popcount(minors & b))) << 8
        return pw | pb << 12
    }

    @inline(__always) private func nonPawnMaterial(_ side: Int) -> Int {
        let s = bb[6 &+ side]
        return 9 &* popcount(bb[QUEEN] & s) &+ 5 &* popcount(bb[ROOK] & s) &+ 3 &* popcount((bb[KNIGHT] | bb[BISHOP]) & s)
    }

    @inline(__always) private func sideOf(_ k: Int) -> Int { (k &- 1 &+ startSide) & 1 }

    // MARK: - Hits

    @inline(__always) private func record(_ theme: Theme, _ side: Int, _ strength: Float, ply: Int) {
        let i = Int(theme.rawValue) &+ side &* 32
        found |= 1 &<< UInt64(i)
        if strength > best[i] { best[i] = strength }
        occurrences[i] &+= 1
        let c = Int(hitPlyCount[i])
        if c < 4 {
            hitPlies[i &* 4 &+ c] = Int32(ply)
            hitPlyCount[i] = UInt8(c &+ 1)
        }
    }

    @inline(__always) private func updateRun(_ theme: Theme, _ side: Int, _ on: Bool, _ k: Int, extra: Float = 0) {
        let i = Int(theme.rawValue) &+ side &* 32
        if on {
            if runs[i].start < 0 { runs[i].start = Int32(k); runs[i].current = 0 }
            if extra > runs[i].current { runs[i].current = extra }
            let len = Int32(k) &- runs[i].start &+ 1
            if len > runs[i].bestLen { runs[i].bestLen = len; runs[i].bestStart = runs[i].start }
            if runs[i].bestStart == runs[i].start { runs[i].extra = runs[i].current }
        } else {
            runs[i].start = -1
        }
    }

    // MARK: - Una jugada

    private func apply(_ m: ThemeMove, k: Int) throws(ThemeError) {
        let f = Int(m.from), t = Int(m.to)
        let us = sideOf(k), them = us ^ 1
        guard f < 64, t < 64, f != t else { throw .illegalMove(index: k - 1) }
        let fb = bit(f), tb = bit(t)
        guard bb[6 &+ us] & fb != 0, bb[6 &+ us] & tb == 0 else { throw .illegalMove(index: k - 1) }
        let pt = typeAt(fb)
        var fl: UInt8 = 0
        if pt >= KNIGHT && pt <= QUEEN && (wantSacrifice || wantExchange || wantGreek) {
            let occ0 = bb[6] | bb[7]
            let att = attackersTo(f, occ0)
            let enemyAtt = att & bb[6 &+ them]
            if enemyAtt != 0 {
                fl |= 4
                var lower = false
                var x = enemyAtt
                while x != 0 {
                    let sq = lsb(x); x &= x &- 1
                    if value(typeAt(bit(sq))) < value(pt) { lower = true; break }
                }
                if lower || att & bb[6 &+ us] == 0 { fl |= 1 }
            }
            if pt == ROOK && bb[6 &+ them] & tb != 0 {
                let ct = typeAt(tb)
                if (ct == KNIGHT || ct == BISHOP) && attacks(ct, them, t, occ0) & (bb[KING] | bb[QUEEN]) & bb[6 &+ us] != 0 { fl |= 2 }
            }
        }
        var captured = NONE
        var capSq = t
        if bb[6 &+ them] & tb != 0 {
            let ct = typeAt(tb)
            guard ct != KING else { throw .illegalMove(index: k - 1) }
            captured = UInt8(ct)
        } else if pt == PAWN && (f & 7) != (t & 7) {
            capSq = us == 0 ? t &- 8 : t &+ 8
            guard bb[PAWN] & bb[6 &+ them] & bit(capSq) != 0 else { throw .illegalMove(index: k - 1) }
            captured = UInt8(PAWN)
        }
        if captured != NONE {
            let cb = ~bit(capSq)
            bb[Int(captured)] &= cb
            bb[6 &+ them] &= cb
        }
        bb[pt] ^= fb
        bb[6 &+ us] ^= fb | tb
        var newType = pt
        let lastRank = t >> 3 == 7 || t >> 3 == 0
        if pt == PAWN && lastRank { newType = m.promotion >= 1 && m.promotion <= 4 ? Int(m.promotion) : QUEEN }
        bb[newType] |= tb
        var isCastle = false
        if pt == KING && (t &- f == 2 || f &- t == 2) {
            isCastle = true
            let (rf, rt) = t > f ? (f &+ 3, f &+ 1) : (f &- 4, f &- 1)
            let rm = bit(rf) | bit(rt)
            guard bb[ROOK] & bb[6 &+ us] & bit(rf) != 0 else { throw .illegalMove(index: k - 1) }
            bb[ROOK] ^= rm
            bb[6 &+ us] ^= rm
            if us == 0 { castled.0 = t > f ? 1 : 2 } else { castled.1 = t > f ? 1 : 2 }
        }
        epSquare = pt == PAWN && (t &- f == 16 || f &- t == 16) ? (f &+ t) >> 1 : -1

        var delta: Int16 = captured != NONE ? pieceValue[Int(captured)] : 0
        if newType != pt { delta += pieceValue[newType] - 1 }
        bal[k] = bal[k - 1] + (us == 0 ? delta : -delta)
        capt[k] = captured
        mvType[k] = UInt8(pt)
        fromSq[k] = UInt8(f)
        toSq[k] = UInt8(t)
        counts[k] = captured != NONE || newType != pt ? packedCounts() : counts[k - 1]
        flags[k] = fl
        pinAt[k] = 0

        let occ = bb[6] | bb[7]
        let theirKing = lsb(bb[KING] & bb[6 &+ them])
        let checkers = attackersTo(theirKing, occ) & bb[6 &+ us]
        checks[k] = UInt8(popcount(checkers))

        // Tácticos durante la pasada.
        if wantFork { forkCheck(k, us, newType, t, occ) }
        if wantPin { pinCheck(k, us, t, occ) }
        if wantDiscovered && !isCastle { discoveredCheck(k, us, f, t, occ, checkers) }
        if wantGreek && pt == BISHOP && captured == UInt8(PAWN) && checkers != 0 {
            let h7 = us == 0 ? 55 : 15, g8 = us == 0 ? 62 : 6
            if t == h7 && theirKing == g8 { greek.append(Candidate(ply: Int32(k), mask: 0)) }
        }
        if wantOpposite && captured == NONE { oppositeCheck(k, us, pt, t) }
        if wantKingWalk && pt == KING && !isCastle { kingWalkCheck(k, us, t) }
        if wantRace && pt == PAWN && relRank(t, us) >= 6 && (captured == NONE || newType != pt) {
            raceCheck(k, us, t, promoted: newType != pt)
        }
        if newType != pt {
            anyPromotion = true
            if us == 0 { passedPromoted.0 = true } else { passedPromoted.1 = true }
        }
        if wantMinority && pt == PAWN && captured == NONE && (t & 7) == 1 && relRank(t, us) == 4 { minorityCheck(k, us) }
        if wantStrategic { strategic(k, us, pt, t) }
    }

    // MARK: Doble ataque

    @inline(__always) private func forkCheck(_ k: Int, _ us: Int, _ type: Int, _ t: Int, _ occ: UInt64) {
        let enemy = bb[7 &- us]
        let hit = attacks(type, us, t, occ) & enemy
        guard hit & (hit &- 1) != 0 else { return }
        let higher: UInt64
        switch type {
        case PAWN: higher = ~bb[PAWN]
        case KNIGHT, BISHOP: higher = bb[ROOK] | bb[QUEEN] | bb[KING]
        case ROOK: higher = bb[QUEEN] | bb[KING]
        case QUEEN: higher = bb[KING]
        default: higher = 0
        }
        var targets = hit & higher
        var rest = hit & ~targets & ~bb[PAWN]
        while rest != 0 {
            let s = lsb(rest); rest &= rest &- 1
            if attackersTo(s, occ) & enemy == 0 { targets |= bit(s) }
        }
        if targets & (targets &- 1) != 0 {
            forks.append(Candidate(ply: Int32(k), mask: targets, square: Int8(t)))
        }
    }

    // MARK: Clavada

    @inline(__always) private func pinCheck(_ k: Int, _ us: Int, _ t: Int, _ occ: UInt64) {
        let mine = bb[6 &+ us], theirs = bb[7 &- us]
        let diag = (bb[BISHOP] | bb[QUEEN]) & mine
        let orth = (bb[ROOK] | bb[QUEEN]) & mine
        var pinned: UInt64 = 0, byMove: UInt64 = 0
        if diag | orth != 0 {
            var targets = (bb[KING] | bb[QUEEN]) & theirs
            while targets != 0 {
                let T = lsb(targets); targets &= targets &- 1
                let isKing = bb[KING] & bit(T) != 0
                let pd = isKing ? diag : diag & ~bb[QUEEN]
                let po = isKing ? orth : orth & ~bb[QUEEN]
                for dir in 0 ..< 8 {
                    let pinners = dir & 1 == 0 ? po : pd
                    if rays[dir &* 64 &+ T] & pinners == 0 { continue }
                    let first = firstBlocker(dir, T, occ)
                    if first < 0 || theirs & bit(first) == 0 { continue }
                    let second = firstBlocker(dir, first, occ)
                    if second >= 0 && pinners & bit(second) != 0 {
                        pinned |= bit(first)
                        if second == t { byMove |= bit(first) }
                    }
                }
            }
        }
        let prev = us == 0 ? pinnedBy.0 : pinnedBy.1
        let fresh = pinned & byMove & ~prev & ~bb[PAWN]
        pinAt[k] = pinned
        if fresh != 0 { pins.append(Candidate(ply: Int32(k), mask: fresh)) }
        if us == 0 { pinnedBy.0 = pinned } else { pinnedBy.1 = pinned }
    }

    // MARK: Descubierta

    @inline(__always) private func discoveredCheck(_ k: Int, _ us: Int, _ f: Int, _ t: Int, _ occ: UInt64, _ checkers: UInt64) {
        let mine = bb[6 &+ us], theirs = bb[7 &- us]
        let diag = (bb[BISHOP] | bb[QUEEN]) & mine
        let orth = (bb[ROOK] | bb[QUEEN]) & mine
        for line in 0 ..< 4 {
            let sliders = line & 1 == 0 ? orth : diag
            let dA = line, dB = line &+ 4
            if (rays[dA &* 64 &+ f] | rays[dB &* 64 &+ f]) & sliders == 0 { continue }
            let a = firstBlocker(dA, f, occ), b = firstBlocker(dB, f, occ)
            if a < 0 || b < 0 || a == t || b == t { continue }
            var slider = -1, target = -1
            if sliders & bit(a) != 0 && theirs & bit(b) != 0 { slider = a; target = b }
            else if sliders & bit(b) != 0 && theirs & bit(a) != 0 { slider = b; target = a }
            if slider < 0 { continue }
            let tt = typeAt(bit(target)), st = typeAt(bit(slider))
            var valid = tt == KING || value(tt) > value(st)
            if !valid && tt != PAWN && attackersTo(target, occ) & theirs == 0 { valid = true }
            if valid {
                let double = checkers & (checkers &- 1) != 0
                discovered.append(Candidate(ply: Int32(k), mask: bit(target), square: Int8(target), flag: tt == KING || double))
            }
        }
    }

    // MARK: Enroques opuestos, paseo del rey, carrera, minoría

    @inline(__always) private func oppositeCheck(_ k: Int, _ us: Int, _ pt: Int, _ t: Int) {
        guard pt == PAWN, castled.0 != 0, castled.1 != 0, castled.0 != castled.1 else { return }
        guard bb[QUEEN] & bb[6 &+ us] != 0, relRank(t, us) >= 3,
              nonPawnMaterial(0) >= 20, nonPawnMaterial(1) >= 20 else { return }
        let wing = us == 0 ? castled.1 : castled.0
        let file = t & 7
        let onWing = wing == 1 ? file >= 5 : file <= 2
        guard onWing else { return }
        // Empujes seguidos: cada uno a ≤ 12 plies del anterior.
        let o = us * 3
        if stormStreak[o] > 0 && Int32(k) - stormStreak[o] <= 12 {
            stormStreak[o + 1] += 1
        } else {
            stormStreak[o + 1] = 1; stormStreak[o + 2] = Int32(k)
        }
        stormStreak[o] = Int32(k)
        let count = Int(stormStreak[o + 1])
        if us == 0 {
            if count > storm.0 { storm.0 = count; stormPlies.0 = stormStreak[o + 2] }
        } else {
            if count > storm.1 { storm.1 = count; stormPlies.1 = stormStreak[o + 2] }
        }
    }

    @inline(__always) private func kingWalkCheck(_ k: Int, _ us: Int, _ t: Int) {
        let r = relRank(t, us)
        guard r >= 3, checks[k - 1] == 0, k < 3 || checks[k - 3] == 0 else { return }
        let them = us ^ 1
        guard !anyPromotion, bb[QUEEN] & bb[6 &+ them] != 0, nonPawnMaterial(them) >= 14,
              nonPawnMaterial(us) >= 13, (us == 0 ? Int(bal[k]) : -Int(bal[k])) > -5 else { return }
        if us == 0 {
            walkCount.0 += 1; if r > walkRank.0 { walkRank.0 = r; walkPly.0 = Int32(k) }
        } else {
            walkCount.1 += 1; if r > walkRank.1 { walkRank.1 = r; walkPly.1 = Int32(k) }
        }
    }

    @inline(__always) private func raceCheck(_ k: Int, _ us: Int, _ t: Int, promoted: Bool) {
        // Peón pasado (o que acaba de coronar) en material de final.
        guard nonPawnMaterial(0) <= 13, nonPawnMaterial(1) <= 13 else { return }
        if !promoted {
            let wp = bb[PAWN] & bb[6], bp = bb[PAWN] & bb[7]
            let passed = us == 0
                ? wp & ~southFill((bp | eastOne(bp) | westOne(bp)) >> 8)
                : bp & ~northFill((wp | eastOne(wp) | westOne(wp)) << 8)
            guard passed & bit(t) != 0 else { return }
        }
        // ¿El otro bando tiene ahora mismo un peón en su 7.ª (o acaba de coronar)?
        let them = us ^ 1
        let their7 = bb[PAWN] & bb[6 &+ them] & (them == 0 ? rankMask(6) : rankMask(1))
        raceEvents.append(Candidate(ply: Int32(k), mask: their7 != 0 ? 1 : 0, square: Int8(t), flag: promoted))
    }

    @inline(__always) private func minorityCheck(_ k: Int, _ us: Int) {
        let mine = bb[PAWN] & bb[6 &+ us], theirs = bb[PAWN] & bb[7 &- us]
        let qside = fileMask(0) | fileMask(1) | fileMask(2)
        guard popcount(mine & qside) < popcount(theirs & qside),
              theirs & fileMask(2) != 0, mine & fileMask(2) == 0 else { return }
        // Estructura Carlsbad: peones d trabados (d4 contra d5) y peón c rival en su 3.ª (c6 / c3).
        let myD = mine & fileMask(3)
        let blockedD = us == 0 ? (myD << 8) & theirs : (myD >> 8) & theirs
        let theirC3 = theirs & fileMask(2) & (us == 0 ? rankMask(5) : rankMask(2))
        guard blockedD != 0, theirC3 != 0, theirs & fileMask(1) != 0,
              nonPawnMaterial(0) >= 13, nonPawnMaterial(1) >= 13 else { return }
        minority.append(Candidate(ply: Int32(k), mask: 0, flag: nonPawnMaterial(0) >= 13 && nonPawnMaterial(1) >= 13))
    }

    // MARK: Estratégicos por posición

    private func strategic(_ k: Int, _ us: Int, _ pt: Int, _ t: Int) {
        let wp = bb[PAWN] & bb[6], bp = bb[PAWN] & bb[7]
        let pawns = wp | bp
        let npmW = nonPawnMaterial(0), npmB = nonPawnMaterial(1)
        let middle = npmW >= 13 && npmB >= 13
        let center = fileMask(2) | fileMask(3) | fileMask(4) | fileMask(5)
        let openFiles = ~fileFill(pawns)
        let wpAtt = whitePawnAttacks(wp), bpAtt = blackPawnAttacks(bp)
        // Casillas que los peones rivales podrán atacar algún día.
        let bSpan = southFill(bpAtt), wSpan = northFill(wpAtt)
        let wPassed = wp & ~southFill((bp | eastOne(bp) | westOne(bp)) >> 8)
        let bPassed = bp & ~northFill((wp | eastOne(wp) | westOne(wp)) << 8)

        for side in 0 ..< 2 {
            let mine = bb[6 &+ side], theirs = bb[7 &- side]
            let myPawns = side == 0 ? wp : bp, theirPawns = side == 0 ? bp : wp
            let npmMine = side == 0 ? npmW : npmB, npmTheirs = side == 0 ? npmB : npmW
            let myB = bb[BISHOP] & mine, theirB = bb[BISHOP] & theirs

            // Peón de dama aislado.
            // Clásico: un solo peón d en d4 (d5 las negras) o d5 (d4), sin peones propios en c ni e
            // y sin peón d rival (columna semiabierta para el rival).
            let dPawn = myPawns & fileMask(3)
            let dHome = rankMask(3) | rankMask(4)
            // Y con peón c o e rival (si no, es un peón d pasado, otra estructura) y ≥ 5 peones cada uno.
            let iqp = middle && popcount(dPawn) == 1 && dPawn & dHome != 0
                && myPawns & (fileMask(2) | fileMask(4)) == 0 && theirPawns & fileMask(3) == 0
                && dPawn & (side == 0 ? wPassed : bPassed) == 0
                && popcount(myPawns) >= 5 && popcount(theirPawns) >= 5
            var pushed: Float = 0
            if iqp && side == us && pt == PAWN && (t & 7) == 3 && relRank(t, side) == 4 { pushed = 1 }
            updateRun(.isolatedQueenPawn, side, iqp, k, extra: pushed)

            // Pareja de alfiles contra alfil y caballo / dos caballos.
            let pair = myB & lightSquares != 0 && myB & darkSquares != 0 && popcount(theirB) <= 1
                && bb[KNIGHT] & theirs != 0 && npmTheirs >= 6
            updateRun(.bishopPair, side, pair, k)

            let oneEach = popcount(myB) == 1 && popcount(theirB) == 1
            // Alfiles de distinto color (se apunta para los dos bandos, se calcula una vez).
            if side == 0 {
                let sameHeavy = popcount(bb[ROOK] & mine) == popcount(bb[ROOK] & theirs)
                    && popcount(bb[QUEEN] & mine) == popcount(bb[QUEEN] & theirs)
                let ocb = oneEach && bb[KNIGHT] == 0 && sameHeavy
                    && (myB & lightSquares != 0) != (theirB & lightSquares != 0)
                var phase: Float = 0
                if ocb {
                    let others = bb[QUEEN] | bb[ROOK] | bb[KNIGHT]
                    phase = others == 0 ? 1 : (bb[QUEEN] == 0 && bb[KNIGHT] == 0 ? 0.75 : 0.5)
                }
                updateRun(.oppositeColoredBishops, 0, ocb, k, extra: phase)
                updateRun(.oppositeColoredBishops, 1, ocb, k, extra: phase)
            }

            // Alfil bueno contra alfil malo.
            var goodBad = false
            // Material igualado aparte de los alfiles (un alfil cada uno: basta el balance).
            let samePieces = popcount(bb[KNIGHT] & mine) == popcount(bb[KNIGHT] & theirs)
                && popcount(bb[ROOK] & mine) == popcount(bb[ROOK] & theirs)
                && popcount(bb[QUEEN] & mine) == popcount(bb[QUEEN] & theirs)
            if oneEach && samePieces && popcount(theirPawns) >= 3 && abs(Int(bal[k])) <= 1 {
                let myColor = myB & lightSquares != 0 ? lightSquares : darkSquares
                let theirColor = theirB & lightSquares != 0 ? lightSquares : darkSquares
                let mineOnColor = popcount(myPawns & myColor)
                let theirsOnColor = theirPawns & theirColor
                let tc = popcount(theirsOnColor)
                if tc >= 3 && tc * 5 >= popcount(theirPawns) * 3 && mineOnColor * 3 <= popcount(myPawns) {
                    // Peones malos fijos: bloqueados por un peón nuestro delante.
                    // Peones malos fijos en el centro (c–f): bloqueados por un peón nuestro delante.
                    let blocked = (side == 0 ? theirsOnColor & (myPawns << 8) : theirsOnColor & (myPawns >> 8)) & center
                    goodBad = popcount(blocked) >= 2
                }
            }
            updateRun(.goodVsBadBishop, side, goodBad, k)

            // Caballo en puesto avanzado.
            // Filas 5–6 en b–g; la 4.ª solo en c–f y bloqueando un peón rival.
            let deepZone: UInt64 = side == 0 ? 0x0000_7E7E_0000_0000 : 0x0000_0000_7E7E_0000
            let fourth = (side == 0 ? rankMask(3) : rankMask(4)) & center
                & (side == 0 ? theirPawns >> 8 : theirPawns << 8)
            let zone = deepZone | fourth
            let support = side == 0 ? wpAtt : bpAtt
            let enemySpan = side == 0 ? bSpan : wSpan
            let outposts = bb[KNIGHT] & mine & zone & support & ~enemySpan
            var sixth: Float = 0
            if outposts != 0 {
                let r6 = side == 0 ? rankMask(5) : rankMask(2)
                sixth = outposts & r6 != 0 ? 1 : 0.5
            }
            let theirPieces = npmTheirs - 9 * popcount(bb[QUEEN] & theirs)
            updateRun(.outpostKnight, side, outposts != 0 && theirPieces >= 6, k, extra: sixth)

            // Columna abierta.
            let myHeavy = (bb[ROOK] | bb[QUEEN]) & mine
            let theirHeavy = (bb[ROOK] | bb[QUEEN]) & theirs
            var controlFiles = fileFill(bb[ROOK] & mine & openFiles) & ~fileFill(theirHeavy & openFiles)
            controlFiles &= openFiles
            // Con estructura de medio juego (≥ 10 peones); el doblaje o la penetración, en la misma columna.
            let open = controlFiles != 0 && theirHeavy != 0 && popcount(pawns) >= 10
            var openExtra: Float = 0
            if open {
                let deep = side == 0 ? rankMask(6) | rankMask(7) : rankMask(0) | rankMask(1)
                var files = controlFiles & rank1
                while files != 0 {
                    let f = lsb(files); files &= files &- 1
                    let fm = fileMask(f)
                    var e: Float = popcount(myHeavy & fm) >= 2 ? 0.5 : 0
                    if bb[ROOK] & mine & fm & deep != 0 { e = e > 0 ? 0.7 : 0.4 }
                    openExtra = max(openExtra, e)
                }
            }
            updateRun(.openFile, side, open, k, extra: openExtra)

            // Torre en séptima.
            let r7 = side == 0 ? rankMask(6) : rankMask(1)
            let r8 = side == 0 ? rankMask(7) : rankMask(0)
            let rooks7 = bb[ROOK] & mine & r7
            let pawns7 = popcount(theirPawns & r7)
            var seventh = rooks7 != 0 && ((bb[KING] & theirs & r8 != 0 && pawns7 >= 1) || pawns7 >= 2)
            if seventh {
                // La torre tiene que barrer la fila: atacar un peón en 7.ª o casillas de escape del rey.
                let theirKing = bb[KING] & theirs
                let escape = theirKing & r8 != 0 ? kingT[lsb(theirKing)] & r7 : 0
                var hits = false
                var rs = rooks7
                while rs != 0 {
                    let sq = lsb(rs); rs &= rs &- 1
                    let along = (ray(2, sq, pawns | bb[6] | bb[7]) | ray(6, sq, pawns | bb[6] | bb[7]))
                    if along & (theirPawns | escape) != 0 { hits = true }
                }
                seventh = hits
            }
            updateRun(.seventhRank, side, seventh, k, extra: seventh && popcount(myHeavy & r7) >= 2 ? 1 : 0)

            // Peón pasado en sexta o más.
            let passed = side == 0 ? wPassed : bPassed
            let far = side == 0 ? rankMask(5) | rankMask(6) : rankMask(2) | rankMask(1)
            let farPassed = passed & far
            var passedExtra: Float = 0
            if farPassed != 0 {
                passedExtra = farPassed & (side == 0 ? rankMask(6) : rankMask(1)) != 0 ? 0.7 : 0.5
                if farPassed & support != 0 { passedExtra += 0.1 }
            }
            updateRun(.passedPawn, side, farPassed != 0, k, extra: passedExtra)

            // Ventaja de espacio.
            var space = false
            var spaceExtra: Float = 0
            if middle && popcount(myPawns) >= 6 && popcount(theirPawns) >= 6 {
                let fifthPlus = side == 0 ? 0xFFFF_FFFF_0000_0000 as UInt64 : 0x0000_0000_FFFF_FFFF as UInt64
                let theirFifth = side == 0 ? 0x0000_0000_FFFF_FFFF as UInt64 : 0xFFFF_FFFF_0000_0000 as UInt64
                let adv = myPawns & center & fifthPlus & ~(side == 0 ? wPassed : bPassed)
                let c = popcount(adv)
                if c >= 2 && theirPawns & center & theirFifth == 0 {
                    // Centro trabado y cadena: algún peón adelantado bloqueado y alguno apoyado por otro peón.
                    let front = side == 0 ? adv << 8 : adv >> 8
                    if front & theirPawns != 0 && adv & support & (fileMask(3) | fileMask(4)) != 0 {
                        space = true; spaceExtra = Float(c - 2) * 0.1
                    }
                }
            }
            updateRun(.spaceAdvantage, side, space, k, extra: spaceExtra)
            _ = npmMine
        }
    }

    // MARK: - Material asentado

    /// Índice donde termina la cadena de capturas que empieza en la jugada k.
    @inline(__always) private func chainEnd(_ k: Int) -> Int {
        var j = k
        while j < n && capt[j + 1] != NONE && j + 1 - k <= 8 { j += 1 }
        return j
    }

    /// Balance antes de la jugada k, retrocediendo por la cadena de capturas previa.
    @inline(__always) private func base(_ k: Int) -> Int {
        var i = k - 1
        while i >= 1 && capt[i] != NONE && k - 1 - i < 8 { i -= 1 }
        return Int(bal[i])
    }

    @inline(__always) private func settled(_ k: Int) -> Int { Int(bal[chainEnd(k)]) }

    /// Material sin peones del bando en el índice k (de los recuentos guardados).
    private func npmAt(_ k: Int, _ side: Int) -> Int {
        let c = counts[max(0, k)] >> UInt32(side * 12)
        return 9 * Int(c & 15) + 5 * Int((c >> 4) & 15) + 3 * Int((c >> 8) & 15)
    }

    @inline(__always) private func gain(_ side: Int, from b: Int, to s: Int) -> Int { side == 0 ? s - b : b - s }

    private func wins(_ side: Int) -> Bool { side == 0 ? result == .whiteWins : result == .blackWins }
    private func loses(_ side: Int) -> Bool { side == 0 ? result == .blackWins : result == .whiteWins }

    private func tacticalStrength(_ g: Int) -> Float { min(1, 0.3 + 0.075 * Float(g)) }

    // MARK: - Cierre

    private func finish() {
        // Doble ataque: una de las piezas atacadas cae en las 5 plies siguientes y se gana material.
        for c in forks {
            let k = Int(c.ply), us = sideOf(k)
            let b = base(k)
            var j = k + 1
            while j <= min(n, k + 5) {
                if sideOf(j) == us && capt[j] != NONE && c.mask & bit(Int(toSq[j])) != 0 {
                    let g = gain(us, from: b, to: settled(j))
                    if g >= 2 && Int(fromSq[j]) == Int(c.square) {
                        record(.fork, us, tacticalStrength(g), ply: k)
                    }
                    break
                }
                j += 1
            }
        }
        // Clavada: la pieza clavada cae en las 6 plies siguientes con ganancia.
        for c in pins {
            let k = Int(c.ply), us = sideOf(k)
            let b = base(k)
            var j = k + 1
            while j <= min(n, k + 6) {
                if sideOf(j) == us && capt[j] != NONE && c.mask & bit(Int(toSq[j])) != 0 {
                    // La clavada sigue tras nuestra jugada anterior y se gana material en esa casilla.
                    if c.mask & pinAt[j - 2] & bit(Int(toSq[j])) != 0 {
                        var e = j
                        while e < n && capt[e + 1] != NONE && toSq[e + 1] == toSq[j] { e += 1 }
                        // Ganancia en la peor de las plies hasta 4 después (contracapturas en otra casilla).
                        var g = gain(us, from: Int(bal[j - 1]), to: Int(bal[e]))
                        var x = e + 1
                        while x <= min(n, e + 4) { g = min(g, gain(us, from: Int(bal[j - 1]), to: Int(bal[x]))); x += 1 }
                        if g >= 2 { record(.pin, us, tacticalStrength(g), ply: k) }
                    }
                    break
                }
                j += 1
            }
        }
        let mate = finalMate()
        // Descubierta: captura del objetivo, o la propia pieza que se mueve captura, con ganancia; o mate.
        var lastDiscovered = -1
        for c in discovered where Int(c.ply) != lastDiscovered {
            let k = Int(c.ply), us = sideOf(k)
            let b = base(k)
            var ok = false, g = 0
            var j = k
            while j <= min(n, k + 4) {
                if sideOf(j) == us && capt[j] != NONE
                    && ((j == k && c.flag) || c.mask & bit(Int(toSq[j])) != 0 || (c.flag && j == k + 2)) {
                    g = max(g, gain(us, from: b, to: settled(j)))
                    if g >= 2 { ok = true; break }
                }
                j += 1
            }
            if !ok, mate.mated >= 0, mate.mated != us, n - k <= 4 { ok = true; g = 9 }
            if ok {
                record(.discoveredAttack, us, min(1, tacticalStrength(g) + (c.flag ? 0.1 : 0)), ply: k)
                lastDiscovered = k
            }
        }
        if wantSacrifice || wantExchange { sacrifices() }
        if wantGreek {
            for c in greek {
                let k = Int(c.ply), us = sideOf(k)
                let g5 = us == 0 ? 38 : 30, h5 = us == 0 ? 39 : 31
                var follow = false
                var j = k + 2
                while j <= min(n, k + 6) {
                    if (mvType[j] == UInt8(KNIGHT) && Int(toSq[j]) == g5) || (mvType[j] == UInt8(QUEEN) && Int(toSq[j]) == h5) {
                        follow = true; break
                    }
                    j += 2
                }
                guard follow, flags[k] & 4 == 0, capt[k - 1] == NONE, k < 2 || capt[k - 2] == NONE else { continue }
                // Aceptado con el rey o rehusado (no recaptura de pieza), sin otra captura grande de S
                // fuera de g5 (g4) en 6 plies, y con las dos damas 6 plies después.
                let taken = k < n && capt[k + 1] != NONE && toSq[k + 1] == toSq[k]
                if taken && mvType[k + 1] != UInt8(KING) { continue }
                var bigCapture = false
                j = k + 2
                while j <= min(n, k + 6) {
                    if sideOf(j) == us && capt[j] != NONE && capt[j] >= UInt8(KNIGHT) && Int(toSq[j]) != g5 { bigCapture = true }
                    j += 1
                }
                let cq = counts[min(n, k + 6)]
                guard !bigCapture, cq & 15 != 0, (cq >> 12) & 15 != 0 else { continue }
                var s: Float = 0.6
                if taken { s += 0.2 }
                if wins(us) { s += 0.2 }
                record(.greekGift, us, s, ply: k)
            }
        }
        if wantMate || wantBackRank || wantSmothered { mates(mate) }
        if wantOpposite {
            for side in 0 ..< 2 {
                let s = side == 0 ? storm.0 : storm.1
                guard s >= 2 else { continue }
                var st = min(1, 0.3 + 0.12 * Float(s))
                if wins(side) { st = min(1, st + 0.1) }
                record(.oppositeCastlingAttack, side, st, ply: Int(side == 0 ? stormPlies.0 : stormPlies.1))
            }
        }
        if wantKingWalk {
            for side in 0 ..< 2 {
                let c = side == 0 ? walkCount.0 : walkCount.1
                let r = side == 0 ? walkRank.0 : walkRank.1
                guard (c >= 2 && r >= 4) || r >= 5 else { continue }
                var s: Float = r >= 5 ? 0.8 : (r == 4 ? 0.6 : 0.4)
                if wins(side) { s += 0.2 }
                record(.kingWalk, side, s, ply: Int(side == 0 ? walkPly.0 : walkPly.1))
            }
        }
        if wantRace {
            // Eventos válidos: coronación, o el peón sobrevive a la respuesta en su casilla.
            var firstW = -1, firstB = -1, lastPair = (-1, -1)
            var lastW = -1, lastB = -1, lastWPromoted = false, lastBPromoted = false
            var promotedW = false, promotedB = false
            for e in raceEvents {
                let k = Int(e.ply)
                if !e.flag && k < n && capt[k + 1] != NONE && Int(toSq[k + 1]) == Int(e.square) { continue }
                if sideOf(k) == 0 { if firstW < 0 { firstW = k }; promotedW = promotedW || e.flag }
                else { if firstB < 0 { firstB = k }; promotedB = promotedB || e.flag }
                let other = sideOf(k) == 0 ? lastB : lastW
                let otherPromoted = sideOf(k) == 0 ? lastBPromoted : lastWPromoted
                if other >= 0 && k - other <= 4 && (e.mask == 1 || otherPromoted) && lastPair.0 < 0 { lastPair = (other, k) }
                if sideOf(k) == 0 { lastW = k; lastWPromoted = e.flag } else { lastB = k; lastBPromoted = e.flag }
            }
            if lastPair.0 >= 0 {
                let s: Float = promotedW && promotedB ? 1 : (promotedW || promotedB ? 0.8 : 0.5)
                for side in 0 ..< 2 {
                    record(.promotionRace, side, s, ply: lastPair.0)
                    let i = Int(Theme.promotionRace.rawValue) + 32 * side
                    hitPlies[i * 4 + 1] = Int32(lastPair.1); hitPlyCount[i] = 2
                }
            }
        }
        if wantMinority {
            for c in minority {
                let k = Int(c.ply), us = sideOf(k)
                var s: Float = 0.5
                var j = k + 2
                while j <= min(n, k + 12) {
                    if mvType[j] == UInt8(PAWN) && capt[j] != NONE && fromSq[j] & 7 == 1 && toSq[j] & 7 == 2 { s += 0.2; break }
                    j += 2
                }
                if c.flag { s += 0.2 }
                if wins(us) { s += 0.1 }
                record(.minorityAttack, us, s, ply: k)
            }
        }
        if wantFortress { fortress() }
        if wantStrategic { finishRuns() }
        found &= enabled.rawValue
    }

    private func sacrifices() {
        guard n >= 2 else { return }
        for k in 1 ..< n {
            let us = sideOf(k)
            // Solo jugadas en un contexto tranquilo (sin capturas en las dos plies previas), cuya pieza
            // se captura en la jugada siguiente en su casilla de llegada.
            guard mvType[k] >= 1, mvType[k] <= 4, capt[k + 1] != NONE, toSq[k + 1] == toSq[k],
                  capt[k - 1] == NONE, k < 2 || capt[k - 2] == NONE, flags[k] & 1 == 0, checks[k - 1] == 0 else { continue }
            // Dar la pieza por un peón pasado en 6.ª/7.ª es frenar la coronación, no sacrificar.
            if capt[k] == UInt8(PAWN) && relRank(Int(toSq[k]), us ^ 1) >= 5 { continue }
            // Cadena de capturas en esa misma casilla.
            var e = k + 1
            while e < n && capt[e + 1] != NONE && toSq[e + 1] == toSq[k] { e += 1 }
            let b = Int(bal[k - 1])
            let later = e + 4
            guard later <= n else { continue }
            // Medir 4 plies después; si esa jugada es una captura, al final de su cadena.
            let laterSettled = capt[later] != NONE ? settled(later) : Int(bal[later])
            // Sacrificio: tras la cadena quedan 2 o más de material de menos, y siguen 4 plies después.
            if wantSacrifice {
                let d = -gain(us, from: b, to: Int(bal[e]))
                let dLater = -gain(us, from: b, to: laterSettled)
                // Devolver material yendo muy por delante es liquidar, no sacrificar.
                let after = us == 0 ? Int(bal[e]) : -Int(bal[e])
                // Sin ir ≥ 2 por delante antes, y con el déficit en cada ply hasta 4 después de la cadena.
                let before = us == 0 ? b : -b
                var held = true
                var x = e + 1
                while x <= later { if -gain(us, from: b, to: Int(bal[x])) < 2 { held = false; break }; x += 1 }
                if d >= 2 && dLater >= 2 && after <= 1 && before < 2 && held {
                    if !loses(us) {
                        var s = min(1, 0.25 + 0.08 * Float(d))
                        if wins(us) { s = min(1, s + 0.15) }
                        record(.sacrifice, us, s, ply: k)
                    }
                }
            }
            // Calidad: la torre que mueve S se captura en su casilla; tras la cadena S tiene una torre
            // menos y el rival una menor menos (el resto igual), y sigue así 4 plies después.
            // Calidad forzada (la menor daba jaque o atacaba rey o dama) o devuelta yendo ≥ 2 por delante: no.
            let ahead = us == 0 ? Int(bal[k - 1]) : -Int(bal[k - 1])
            // Si la torre no captura nada (se deja tomar), además S no puede perder la partida.
            if wantExchange && mvType[k] == UInt8(ROOK) && flags[k] & 3 == 0 && ahead < 2
                && (capt[k] != NONE || !loses(us)) {
                let c0 = counts[k - 1], c1 = counts[e], c2 = counts[chainEnd(later)]
                let shiftUs = UInt32(us * 12), shiftThem = UInt32((us ^ 1) * 12)
                func q(_ c: UInt32, _ s: UInt32) -> Int { Int((c >> s) & 15) }
                func r(_ c: UInt32, _ s: UInt32) -> Int { Int((c >> (s + 4)) & 15) }
                func m(_ c: UInt32, _ s: UInt32) -> Int { Int((c >> (s + 8)) & 15) }
                let ok1 = r(c1, shiftUs) == r(c0, shiftUs) - 1 && m(c1, shiftThem) == m(c0, shiftThem) - 1
                    && m(c1, shiftUs) == m(c0, shiftUs) && r(c1, shiftThem) == r(c0, shiftThem)
                    && q(c1, shiftUs) == q(c0, shiftUs) && q(c1, shiftThem) == q(c0, shiftThem)
                let ok2 = r(c2, shiftUs) - r(c2, shiftThem) == r(c1, shiftUs) - r(c1, shiftThem)
                    && m(c2, shiftUs) - m(c2, shiftThem) == m(c1, shiftUs) - m(c1, shiftThem)
                if ok1 && ok2 {
                    var s: Float = 0.6
                    if !loses(us) { s += 0.2 }
                    if wins(us) { s += 0.2 }
                    record(.exchangeSacrifice, us, s, ply: k)
                }
            }
        }
    }

    private func fortress() {
        guard result == .draw, n >= 20 else { return }
        let last = Int(bal[n])
        guard last >= 2 || last <= -2 else { return }
        let weak = last > 0 ? 1 : 0
        // Tramo final con 2 o más de material de menos.
        var start = n
        while start > 0 {
            let d = weak == 0 ? -Int(bal[start - 1]) : Int(bal[start - 1])
            if d < 2 { break }
            start -= 1
        }
        let span = n - start
        guard span >= 20 else { return }
        let strong = weak ^ 1
        guard nonPawnMaterial(strong) <= 14 else { return }
        // El fuerte tiene al menos las mismas piezas de cada tipo y le sobra un peón, una torre o una dama.
        let sm = bb[6 + strong], wm = bb[6 + weak]
        func cnt(_ t: Int, _ m: UInt64) -> Int { popcount(bb[t] & m) }
        let minorsS = cnt(KNIGHT, sm) + cnt(BISHOP, sm), minorsW = cnt(KNIGHT, wm) + cnt(BISHOP, wm)
        guard cnt(QUEEN, sm) >= cnt(QUEEN, wm), cnt(ROOK, sm) >= cnt(ROOK, wm), minorsS >= minorsW,
              cnt(PAWN, sm) >= 1 || cnt(ROOK, sm) > cnt(ROOK, wm) || cnt(QUEEN, sm) > cnt(QUEEN, wm) else { return }
        // Jaque continuo (de cualquiera) no es fortaleza: ≥ 3 jaques en las 12 últimas plies.
        var lateChecks = 0
        var j = n
        while j >= 1 && j > n - 12 { if checks[j] > 0 { lateChecks += 1 }; j -= 1 }
        guard lateChecks < 3 else { return }
        // Tablas por contrajuego de un peón pasado del débil en 6.ª/7.ª: tampoco.
        let wp = bb[PAWN] & bb[6], bp = bb[PAWN] & bb[7]
        let weakPassed = weak == 0
            ? wp & ~southFill((bp | eastOne(bp) | westOne(bp)) >> 8) & (rankMask(5) | rankMask(6))
            : bp & ~northFill((wp | eastOne(wp) | westOne(wp)) << 8) & (rankMask(2) | rankMask(1))
        guard weakPassed == 0 else { return }
        // Déficit ≤ 4, el débil no es un rey solo, sin capturas en las 12 últimas plies, y no es ahogado.
        guard abs(last) <= 4, wm & ~bb[KING] != 0 else { return }
        j = n
        while j >= 1 && j > n - 12 { if capt[j] != NONE { return }; j -= 1 }
        if checks[n] == 0 && !hasLegalMove(sideOf(n) ^ 1) { return }
        let d = abs(last)
        let s = min(1, 0.3 + 0.08 * Float(d) + min(0.3, Float(span) / 100))
        record(.fortress, weak, s, ply: start + 1)
    }

    private func finishRuns() {
        func close(_ theme: Theme, min minLen: Int32, needsExtra: Bool = false, _ strength: (Run, Int) -> Float) {
            guard enabled.contains(theme) else { return }
            for side in 0 ..< 2 {
                let r = runs[Int(theme.rawValue) + 32 * side]
                guard r.bestLen >= minLen, !needsExtra || r.extra > 0 else { continue }
                let i = Int(theme.rawValue) + 32 * side
                record(theme, side, strength(r, side), ply: Int(r.bestStart))
                hitPlies[i * 4 + 1] = r.bestStart + r.bestLen - 1
                hitPlyCount[i] = 2
            }
        }
        close(.isolatedQueenPawn, min: 16) { r, _ in 0.4 + min(0.4, Float(r.bestLen) / 80) + r.extra * 0.2 }
        close(.bishopPair, min: 20) { r, side in 0.3 + min(0.5, Float(r.bestLen) / 100) + (self.wins(side) ? 0.2 : 0) }
        close(.goodVsBadBishop, min: 12) { r, side in 0.4 + min(0.4, Float(r.bestLen) / 60) + (self.wins(side) ? 0.2 : 0) }
        close(.outpostKnight, min: 8) { r, _ in 0.3 + min(0.4, Float(r.bestLen) / 60) + (r.extra >= 1 ? 0.2 : 0) }
        close(.openFile, min: 16, needsExtra: true) { r, _ in 0.3 + min(0.3, Float(r.bestLen) / 60) + r.extra * 0.5 }
        close(.seventhRank, min: 6) { r, _ in r.extra >= 1 ? 1 : 0.5 + min(0.3, Float(r.bestLen) / 30) }
        // Peón pasado que dura ≥ 6 plies o corona.
        for side in 0 ..< 2 where enabled.contains(.passedPawn) {
            let i = Int(Theme.passedPawn.rawValue) + 32 * side
            let promoted = side == 0 ? passedPromoted.0 : passedPromoted.1
            if runs[i].bestLen > 0 && runs[i].bestLen < 6 && !promoted { runs[i].bestLen = 0 }
            // Un peón que aparece al final de una partida perdida (y no corona) pide ≥ 10 plies.
            let endsAtLast = Int(runs[i].bestStart + runs[i].bestLen) - 1 == n
            if endsAtLast && loses(side) && !promoted && runs[i].bestLen < 10 { runs[i].bestLen = 0 }
        }
        close(.passedPawn, min: 1) { r, side in
            r.extra + min(0.2, Float(r.bestLen) / 50) + ((side == 0 ? self.passedPromoted.0 : self.passedPromoted.1) ? 0.1 : 0)
        }
        close(.spaceAdvantage, min: 16) { r, _ in 0.4 + min(0.4, Float(r.bestLen) / 80) + r.extra }
        close(.oppositeColoredBishops, min: 16) { r, _ in r.extra * (0.5 + min(0.5, Float(r.bestLen) / 60)) }
    }

    // MARK: - Mate al final

    private struct MateInfo {
        var mated = -1
        var checker = -1
        var checkerType = -1
    }

    private func finalMate() -> MateInfo {
        guard n >= 1, checks[n] > 0 else { return MateInfo() }
        let side = sideOf(n) ^ 1
        guard !hasLegalMove(side) else { return MateInfo() }
        let occ = bb[6] | bb[7]
        let ksq = lsb(bb[KING] & bb[6 + side])
        let checkers = attackersTo(ksq, occ) & bb[7 - side]
        let c = lsb(checkers)
        return MateInfo(mated: side, checker: c, checkerType: typeAt(bit(c)))
    }

    private func mates(_ mate: MateInfo) {
        if mate.mated >= 0 {
            let winner = mate.mated ^ 1
            if wantMate {
                // Plies: los últimos jaques del ganador (hasta 4, en orden).
                var plies: [Int] = []
                var j = n
                while j >= 1 && j >= n - 12 && plies.count < 4 {
                    if sideOf(j) == winner && checks[j] > 0 { plies.append(j) }
                    j -= 1
                }
                // Rematar con todo ganado (dama contra rey solo, mate tras coronar) no es un ataque:
                // el defensor debe tener ≥ 5 de material sin peones cuando empiezan los jaques.
                let first = plies.last ?? n
                if npmAt(first, mate.mated) >= 5 {
                    for p in plies.reversed() { record(.matingAttack, winner, 1, ply: p) }
                    occurrences[Int(Theme.matingAttack.rawValue) + 32 * winner] = 1
                }
            }
            let ksq = lsb(bb[KING] & bb[6 + mate.mated])
            let own = bb[6 + mate.mated]
            if wantSmothered && mate.checkerType == KNIGHT && kingT[ksq] & ~own == 0 {
                record(.smotheredMate, winner, 1, ply: n)
            }
            if wantBackRank && (mate.checkerType == ROOK || mate.checkerType == QUEEN) {
                let back = mate.mated == 0 ? rank1 : rank8
                let krank = ksq >> 3
                if bit(ksq) & back != 0 && mate.checker >> 3 == krank {
                    let front = kingT[ksq] & ~back
                    if front & own == front && popcount(front & bb[PAWN] & own) >= 2 {
                        record(.backRankMate, winner, 1, ply: n)
                    }
                }
            }
            return
        }
        guard wantMate, result == .whiteWins || result == .blackWins else { return }
        let winner = result == .whiteWins ? 0 : 1
        var checkPlies: [Int] = []
        var j = n
        while j >= 1 && j > n - 12 {
            if sideOf(j) == winner && checks[j] > 0 { checkPlies.append(j) }
            j -= 1
        }
        guard checkPlies.count >= 3, bb[QUEEN] & bb[6 + winner] != 0,
              npmAt(checkPlies.last ?? n, winner ^ 1) >= 5,
              (winner == 0 ? Int(bal[(checkPlies.last ?? n) - 1]) : -Int(bal[(checkPlies.last ?? n) - 1])) < 3 else { return }
        let loser = winner ^ 1
        let ksq = lsb(bb[KING] & bb[6 + loser])
        let zone = kingT[ksq] | bit(ksq)
        let occ = bb[6] | bb[7]
        var attackers = 0
        var pieces = bb[6 + winner] & ~bb[PAWN] & ~bb[KING]
        while pieces != 0 {
            let s = lsb(pieces); pieces &= pieces - 1
            if attacks(typeAt(bit(s)), winner, s, occ) & zone != 0 { attackers += 1 }
        }
        guard attackers >= 2 else { return }
        let s = min(0.85, 0.6 + 0.1 * Float(attackers - 2))
        for p in checkPlies.prefix(4).reversed() { record(.matingAttack, winner, s, ply: p) }
        occurrences[Int(Theme.matingAttack.rawValue) + 32 * winner] = 1
    }

    /// ¿Tiene el bando alguna jugada legal? Solo se usa en la última posición, cuando hay jaque.
    private func hasLegalMove(_ side: Int) -> Bool {
        let own = bb[6 + side], opp = bb[7 - side]
        let occ = own | opp
        let ksq = lsb(bb[KING] & own)
        var pieces = own
        while pieces != 0 {
            let from = lsb(pieces); pieces &= pieces - 1
            let type = typeAt(bit(from))
            var targets: UInt64
            if type == PAWN {
                targets = pawnT[side * 64 + from] & (opp | (epSquare >= 0 ? bit(epSquare) : 0))
                let one = side == 0 ? from + 8 : from - 8
                if one >= 0 && one < 64 && occ & bit(one) == 0 {
                    targets |= bit(one)
                    let startRank = side == 0 ? 1 : 6
                    let two = side == 0 ? from + 16 : from - 16
                    if from >> 3 == startRank && occ & bit(two) == 0 { targets |= bit(two) }
                }
            } else {
                targets = attacks(type, side, from, occ) & ~own
            }
            while targets != 0 {
                let to = lsb(targets); targets &= targets - 1
                if legalAfter(side, from: from, to: to, type: type, ksq: ksq) { return true }
            }
        }
        return false
    }

    private func legalAfter(_ side: Int, from: Int, to: Int, type: Int, ksq: Int) -> Bool {
        let own = (bb[6 + side] & ~bit(from)) | bit(to)
        var opp = bb[7 - side] & ~bit(to)
        if type == PAWN && to == epSquare && (from & 7) != (to & 7) {
            opp &= ~bit(side == 0 ? to - 8 : to + 8)
        }
        let occ = own | opp
        let k = type == KING ? to : ksq
        let pawnsOpp = bb[PAWN] & opp
        if pawnT[side * 64 + k] & pawnsOpp != 0 { return false }
        if knightT[k] & bb[KNIGHT] & opp != 0 { return false }
        if kingT[k] & bb[KING] & opp != 0 { return false }
        if bishopAttacks(k, occ) & (bb[BISHOP] | bb[QUEEN]) & opp != 0 { return false }
        if rookAttacks(k, occ) & (bb[ROOK] | bb[QUEEN]) & opp != 0 { return false }
        return true
    }
}

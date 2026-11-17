// Tablas de ataques y máscaras. Se calculan una vez y se leen por puntero en el bucle caliente.

@usableFromInline
final class Tables: @unchecked Sendable {
    static let shared = Tables()

    /// rays[dir * 64 + sq]: casillas desde sq (sin incluirla) en la dirección dir hasta el borde.
    /// Direcciones 0–3 crecientes (N, NE, E, NO: bloqueo con el bit más bajo), 4–7 decrecientes (S, SO, O, SE).
    let rays: UnsafeMutablePointer<UInt64>
    let knight: UnsafeMutablePointer<UInt64>
    let king: UnsafeMutablePointer<UInt64>
    /// pawnAttacks[color * 64 + sq]
    let pawnAttacks: UnsafeMutablePointer<UInt64>

    private init() {
        rays = .allocate(capacity: 8 * 64)
        knight = .allocate(capacity: 64)
        king = .allocate(capacity: 64)
        pawnAttacks = .allocate(capacity: 128)
        let dirs: [(Int, Int)] = [(0, 1), (1, 1), (1, 0), (-1, 1), (0, -1), (-1, -1), (-1, 0), (1, -1)]
        for sq in 0 ..< 64 {
            let f = sq & 7, r = sq >> 3
            for (d, (df, dr)) in dirs.enumerated() {
                var m: UInt64 = 0
                var ff = f + df, rr = r + dr
                while (0 ..< 8).contains(ff), (0 ..< 8).contains(rr) {
                    m |= 1 << UInt64(rr * 8 + ff)
                    ff += df; rr += dr
                }
                rays[d * 64 + sq] = m
            }
            var n: UInt64 = 0
            for (df, dr) in [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)] {
                let ff = f + df, rr = r + dr
                if (0 ..< 8).contains(ff), (0 ..< 8).contains(rr) { n |= 1 << UInt64(rr * 8 + ff) }
            }
            knight[sq] = n
            var k: UInt64 = 0
            for df in -1 ... 1 {
                for dr in -1 ... 1 where df != 0 || dr != 0 {
                    let ff = f + df, rr = r + dr
                    if (0 ..< 8).contains(ff), (0 ..< 8).contains(rr) { k |= 1 << UInt64(rr * 8 + ff) }
                }
            }
            king[sq] = k
            var w: UInt64 = 0, b: UInt64 = 0
            for df in [-1, 1] {
                let ff = f + df
                guard (0 ..< 8).contains(ff) else { continue }
                if r < 7 { w |= 1 << UInt64((r + 1) * 8 + ff) }
                if r > 0 { b |= 1 << UInt64((r - 1) * 8 + ff) }
            }
            pawnAttacks[sq] = w
            pawnAttacks[64 + sq] = b
        }
    }
}

// MARK: - Máscaras fijas

@usableFromInline let fileA: UInt64 = 0x0101_0101_0101_0101
@usableFromInline let fileH: UInt64 = fileA << 7
@usableFromInline let rank1: UInt64 = 0xFF
@usableFromInline let rank8: UInt64 = 0xFF << 56
@usableFromInline let lightSquares: UInt64 = 0x55AA_55AA_55AA_55AA
@usableFromInline let darkSquares: UInt64 = ~lightSquares

@inline(__always) func fileMask(_ f: Int) -> UInt64 { fileA << UInt64(f) }
@inline(__always) func rankMask(_ r: Int) -> UInt64 { rank1 << UInt64(8 * r) }

@inline(__always) func northFill(_ x: UInt64) -> UInt64 {
    var b = x
    b |= b << 8; b |= b << 16; b |= b << 32
    return b
}

@inline(__always) func southFill(_ x: UInt64) -> UInt64 {
    var b = x
    b |= b >> 8; b |= b >> 16; b |= b >> 32
    return b
}

/// Columnas ocupadas por algún bit de x.
@inline(__always) func fileFill(_ x: UInt64) -> UInt64 { northFill(southFill(x)) }

@inline(__always) func eastOne(_ x: UInt64) -> UInt64 { (x << 1) & ~fileA }
@inline(__always) func westOne(_ x: UInt64) -> UInt64 { (x >> 1) & ~fileH }

@inline(__always) func whitePawnAttacks(_ p: UInt64) -> UInt64 { ((p << 9) & ~fileA) | ((p << 7) & ~fileH) }
@inline(__always) func blackPawnAttacks(_ p: UInt64) -> UInt64 { ((p >> 7) & ~fileA) | ((p >> 9) & ~fileH) }

@inline(__always) func lsb(_ x: UInt64) -> Int { x.trailingZeroBitCount }
@inline(__always) func msb(_ x: UInt64) -> Int { 63 - x.leadingZeroBitCount }
@inline(__always) func popcount(_ x: UInt64) -> Int { x.nonzeroBitCount }
@inline(__always) func bit(_ sq: Int) -> UInt64 { 1 &<< UInt64(sq) }

import Testing
import FischerCore
@testable import ChessThemes

/// Partidas aleatorias legales: la reproducción coincide con fischer-core, los mates son mates
/// y los temas estructurales no se disparan con jugadas al azar.
@Suite struct RandomGameTests {
    struct RandomGame {
        let moves: [ResolvedMove]
        let finalPlacement: String
        let isMate: Bool
        let sideToMoveHasMoves: Bool
    }

    static func randomGame(_ rng: inout SplitMix64, maxPlies: Int) throws -> RandomGame {
        var game = Game()
        var moves: [ResolvedMove] = []
        while moves.count < maxPlies {
            let legal = game.availableMoves()
            guard !legal.isEmpty else { break }
            let move = legal[Int(rng.next() % UInt64(legal.count))]
            var promo: PromotionPiece?
            if game.requiresPromotion(move: move) {
                promo = PromotionPiece.allCases[Int(rng.next() % 4)]
            }
            try game.execute(uncheckedMove: move) { promo ?? .queen }
            moves.append(ResolvedMove(move: move, promotion: promo))
        }
        let finished = game.availableMoves().isEmpty
        return RandomGame(moves: moves, finalPlacement: game.position.board.fen(),
                          isMate: finished && game.kingIsChecked, sideToMoveHasMoves: !finished)
    }

    @Test func randomGamesReplayAndStayQuiet() throws {
        var rng = SplitMix64(state: 0xC0FFEE)
        let scanner = ThemeScanner()
        let games = 100
        var counts: [Theme: Int] = [:]
        var mates = 0
        for _ in 0 ..< games {
            let g = try Self.randomGame(&rng, maxPlies: 140)
            let rep = try scanner.report(of: g.moves)
            #expect(scanner.debugPlacement() == g.finalPlacement)
            #expect(scanner.debugSideToMoveHasLegalMove() == g.sideToMoveHasMoves)
            #expect(try scanner.themes(of: g.moves) == rep.themes)
            // Mates en el tablero: solo si fischer-core también ve mate.
            let mateThemes = rep.hits.filter { [.smotheredMate, .backRankMate].contains($0.theme) || ($0.theme == .matingAttack && $0.strength == 1) }
            if !mateThemes.isEmpty { #expect(g.isMate) }
            if g.isMate { mates += 1; #expect(rep.themes.contains(.matingAttack)) }
            for t in rep.themes.themes { counts[t, default: 0] += 1 }
            for h in rep.hits {
                #expect(h.strength > 0 && h.strength <= 1)
                #expect(h.plies.allSatisfy { $0 >= 1 && $0 <= g.moves.count })
            }
        }
        print("frecuencias aleatorias:", counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        // Sin resultado no hay fortaleza; los temas de estructura sostenida casi no salen al azar.
        #expect(counts[.fortress, default: 0] == 0)
        // Temas de intención clara: casi nunca al azar.
        for theme in [Theme.greekGift, .minorityAttack, .spaceAdvantage, .smotheredMate, .backRankMate] {
            #expect(counts[theme, default: 0] * 100 <= games * 2, "\(theme) en \(counts[theme, default: 0]) de \(games)")
        }
        // Estructuras que el azar sí produce a veces (peones bloqueados, rey que pasea): tope más alto.
        for theme in [Theme.isolatedQueenPawn, .goodVsBadBishop, .kingWalk] {
            #expect(counts[theme, default: 0] * 100 <= games * 10, "\(theme) en \(counts[theme, default: 0]) de \(games)")
        }
        #expect(mates > 0)
    }
}

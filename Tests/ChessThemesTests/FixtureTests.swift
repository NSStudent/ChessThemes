import Testing
import FischerCore
@testable import ChessThemes

/// Una partida hecha a mano por tema.
@Suite struct FixtureTests {
    // MARK: Tácticos

    @Test func greekGiftSacrificeAndAttack() throws {
        let r = try report("""
        1.d4 d5 2.Nf3 Nf6 3.e3 e6 4.Bd3 c5 5.c3 Nc6 6.Nbd2 Bd6 7.O-O O-O 8.dxc5 Bxc5 9.e4 Qc7
        10.e5 Nd7 11.Bxh7+ Kxh7 12.Ng5+ Kg8 13.Qh5 Re8 14.Qxf7+ Kh8 15.Qh5+ Kg8 16.Qh7+ Kf8
        """, result: .whiteWins)
        let greek = try #require(r.hit(.greekGift, side: .white))
        #expect(greek.plies == [21])
        #expect(greek.strength == 1)
        #expect(r.hit(.sacrifice, side: .white)?.plies.first == 21)
        #expect(!r.themes.contains(.greekGift, side: .black))
        #expect(!r.themes.contains(.exchangeSacrifice))
    }

    @Test func scholarsMateIsMatingAttack() throws {
        let r = try report("1.e4 e5 2.Bc4 Nc6 3.Qh5 Nf6 4.Qxf7#", result: .whiteWins)
        let mate = try #require(r.hit(.matingAttack, side: .white))
        #expect(mate.strength == 1)
        #expect(mate.plies == [7])
        #expect(!r.themes.contains(.smotheredMate))
        #expect(!r.themes.contains(.backRankMate))
    }

    @Test func smotheredMate() throws {
        let r = try report("1.e4 e5 2.Nf3 Nc6 3.Bc4 Nd4 4.Nxe5 Qg5 5.Nxf7 Qxg2 6.Rf1 Qxe4+ 7.Be2 Nf3#", result: .blackWins)
        #expect(r.hit(.smotheredMate, side: .black)?.plies == [14])
        #expect(r.themes.contains(.matingAttack, side: .black))
        #expect(!r.themes.contains(.backRankMate))
    }

    @Test func backRankMate() throws {
        let fen = "6k1/5ppp/8/7n/7n/8/5PPP/R5K1 w - - 0 1"
        let r = try report("1.Ra8#", fen: fen, result: .whiteWins)
        #expect(r.hit(.backRankMate, side: .white)?.strength == 1)
        #expect(r.themes.contains(.matingAttack, side: .white))
        #expect(!r.themes.contains(.smotheredMate))
    }

    @Test func knightFork() throws {
        let fen = "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1"
        let r = try report("1.Nc7+ Kd7 2.Nxa8", fen: fen)
        let fork = try #require(r.hit(.fork, side: .white))
        #expect(fork.plies == [1])
        #expect(fork.strength > 0.6)
        #expect(!r.themes.contains(.pin))
    }

    @Test func pinWinsThePinnedKnight() throws {
        let fen = "4k3/7p/2n5/8/8/8/3P4/4KB2 w - - 0 1"
        let r = try report("1.Bb5 h6 2.d4 h5 3.d5 h4 4.dxc6", fen: fen)
        #expect(r.hit(.pin, side: .white)?.plies == [1])
        #expect(!r.themes.contains(.fork))
    }

    @Test func discoveredCheckWinsTheQueen() throws {
        let fen = "4k3/1q6/8/8/4B3/8/8/4RK2 w - - 0 1"
        let r = try report("1.Bxb7+ Kd8", fen: fen)
        let d = try #require(r.hit(.discoveredAttack, side: .white))
        #expect(d.plies == [1])
        #expect(d.strength == 1)
    }

    @Test func exchangeSacrifice() throws {
        let fen = "4k3/8/8/3p4/2n5/8/8/2R1K3 w - - 0 1"
        let r = try report("1.Rxc4 dxc4 2.Kd2 Kd7 3.Kc3 Kc6", fen: fen, result: .draw)
        let x = try #require(r.hit(.exchangeSacrifice, side: .white))
        #expect(x.plies == [1])
        #expect(abs(x.strength - 0.8) < 0.001)
    }

    @Test func plainTradeIsNotASacrifice() throws {
        let r = try report("1.e4 e5 2.Nf3 Nc6 3.Bb5 a6 4.Bxc6 dxc6 5.O-O f6 6.d4 exd4 7.Nxd4 c5 8.Nb3 Qxd1 9.Rxd1")
        #expect(!r.themes.contains(.sacrifice))
        #expect(!r.themes.contains(.exchangeSacrifice))
        #expect(!r.themes.contains(.fork))
    }

    @Test func oppositeCastlingPawnStorm() throws {
        let r = try report("""
        1.e4 c5 2.Nf3 d6 3.d4 cxd4 4.Nxd4 Nf6 5.Nc3 g6 6.Be3 Bg7 7.f3 O-O 8.Qd2 Nc6 9.Bc4 Bd7
        10.O-O-O Rc8 11.Bb3 Ne5 12.h4 h5 13.g4 hxg4 14.h5 Nxh5
        """)
        let storm = try #require(r.hit(.oppositeCastlingAttack, side: .white))
        #expect(storm.plies == [23])
        #expect(!r.themes.contains(.oppositeCastlingAttack, side: .black))
    }

    @Test func promotionRace() throws {
        let fen = "K7/8/8/6P1/1p6/8/8/7k w - - 0 1"
        let r = try report("1.g6 b3 2.g7 b2 3.g8=Q b1=Q", fen: fen)
        #expect(r.hit(.promotionRace, side: .white)?.strength == 1)
        #expect(r.themes.contains(.promotionRace, side: .black))
        #expect(r.themes.contains(.passedPawn, side: .white))
    }

    // MARK: Estratégicos

    @Test func minorityAttackInTheCarlsbad() throws {
        let r = try report("""
        1.d4 d5 2.c4 e6 3.Nc3 Nf6 4.cxd5 exd5 5.Bg5 Be7 6.e3 c6 7.Bd3 O-O 8.Qc2 Nbd7 9.Nf3 Re8
        10.O-O Nf8 11.Rab1 Ng6 12.b4 a6 13.a4 Bd6 14.b5 axb5 15.axb5 Bd7 16.bxc6 bxc6
        """)
        let m = try #require(r.hit(.minorityAttack, side: .white))
        #expect(m.plies == [27])
        #expect(m.strength >= 0.89)
        #expect(!r.themes.contains(.minorityAttack, side: .black))
    }

    @Test func isolatedQueenPawn() throws {
        let r = try report("""
        1.e4 c6 2.d4 d5 3.exd5 cxd5 4.c4 Nf6 5.Nc3 e6 6.Nf3 Be7 7.cxd5 Nxd5 8.Bd3 Nc6 9.O-O O-O
        10.Re1 Bf6 11.Be4 Nce7 12.Qd3 g6 13.Bh6 Bg7 14.Bxg7 Kxg7 15.Ne5 Nf5 16.Rad1 Qd6 17.h3 b6
        """)
        let iqp = try #require(r.hit(.isolatedQueenPawn, side: .white))
        #expect(iqp.plies.first == 14)
        #expect(!r.themes.contains(.isolatedQueenPawn, side: .black))
    }

    @Test func bishopPair() throws {
        let fen = "4k3/pp3ppp/2n1b3/8/8/2BB4/PP3PPP/4K3 w - - 0 1"
        let r = try report(shuffle("Ke2 Ke7 Kd2 Kd7", times: 6), fen: fen)
        #expect(r.hit(.bishopPair, side: .white)?.plies == [1, 24])
        #expect(!r.themes.contains(.bishopPair, side: .black))
        #expect(!r.themes.contains(.oppositeColoredBishops))
    }

    @Test func oppositeColoredBishops() throws {
        let fen = "4k3/pp3ppp/3b4/8/8/3B4/PP3PPP/4K3 w - - 0 1"
        let r = try report(shuffle("Ke2 Ke7 Ke1 Ke8", times: 5), fen: fen)
        #expect(r.hit(.oppositeColoredBishops, side: .white)?.strength ?? 0 > 0.69)
        #expect(r.themes.contains(.oppositeColoredBishops, side: .black))
        #expect(!r.themes.contains(.goodVsBadBishop))
    }

    @Test func goodVersusBadBishop() throws {
        let fen = "2b3k1/1p6/p1p1p3/3pP3/3P1P2/P2B4/1P6/6K1 w - - 0 1"
        let r = try report(shuffle("Kf2 Kf8 Kg1 Kg8", times: 4), fen: fen)
        #expect(r.themes.contains(.goodVsBadBishop, side: .white))
        #expect(!r.themes.contains(.goodVsBadBishop, side: .black))
        #expect(!r.themes.contains(.passedPawn))
    }

    @Test func outpostKnight() throws {
        let fen = "r1b1k3/pp3ppp/3p4/3N4/4P3/8/PPP2PPP/R3K3 w - - 0 1"
        let r = try report(shuffle("Kd1 Kd8 Ke1 Ke8", times: 3), fen: fen)
        #expect(r.themes.contains(.outpostKnight, side: .white))
        #expect(!r.themes.contains(.outpostKnight, side: .black))
    }

    @Test func openFile() throws {
        let fen = "r3k3/ppp2ppp/8/8/8/8/PPPR1PPP/3RK3 w - - 0 1"
        let r = try report(shuffle("Ke2 Kf8 Ke1 Ke8", times: 4), fen: fen)
        #expect(r.themes.contains(.openFile, side: .white))
        #expect(!r.themes.contains(.openFile, side: .black))
    }

    @Test func rookOnTheSeventh() throws {
        let fen = "4k3/R4ppp/8/8/8/8/5PPP/6K1 w - - 0 1"
        let r = try report(shuffle("Kf1 Kf8 Ke1 Ke8", times: 2), fen: fen)
        #expect(r.themes.contains(.seventhRank, side: .white))
        #expect(!r.themes.contains(.seventhRank, side: .black))
    }

    @Test func passedPawn() throws {
        let fen = "4k3/8/8/P7/8/8/8/4K3 w - - 0 1"
        let r = try report("1.a6 Kd7 2.a7 Kc6 3.a8=Q+", fen: fen)
        let p = try #require(r.hit(.passedPawn, side: .white))
        #expect(p.strength >= 0.7)
        #expect(!r.themes.contains(.promotionRace))
    }

    @Test func spaceAdvantage() throws {
        let fen = "r1bqkb1r/pp1n1ppp/3pp3/3PP3/2P5/2N5/PP3PPP/R1BQKB1R w KQkq - 0 1"
        let r = try report(shuffle("Nb1 Nb8 Nc3 Nd7", times: 5), fen: fen)
        #expect(r.themes.contains(.spaceAdvantage, side: .white))
        #expect(!r.themes.contains(.spaceAdvantage, side: .black))
    }

    @Test func kingWalkWithQueensOn() throws {
        let fen = "r2qk3/8/8/8/8/8/8/Q3K2R w - - 0 1"
        let r = try report("1.Ke2 Ra7 2.Ke3 Ra8 3.Ke4 Ra7 4.Ke5 Ra8", fen: fen)
        let walk = try #require(r.hit(.kingWalk, side: .white))
        #expect(walk.plies == [7])
        #expect(!r.themes.contains(.kingWalk, side: .black))
    }

    @Test func fortressDraw() throws {
        let fen = "3rk3/7p/4b3/8/8/8/8/R5K1 w - - 0 1"
        let r = try report(shuffle("Kh1 Kf8 Kg1 Ke8", times: 6), fen: fen, result: .draw)
        #expect(r.themes.contains(.fortress, side: .white))
        #expect(!r.themes.contains(.fortress, side: .black))
        let lost = try report(shuffle("Kh1 Kf8 Kg1 Ke8", times: 6), fen: fen, result: .blackWins)
        #expect(!lost.themes.contains(.fortress))
    }

    // MARK: API

    @Test func bitsetMatchesReportAndSubsets() throws {
        let moves = try resolved("1.e4 e5 2.Nf3 Nc6 3.Bc4 Nd4 4.Nxe5 Qg5 5.Nxf7 Qxg2 6.Rf1 Qxe4+ 7.Be2 Nf3#")
        let scanner = ThemeScanner()
        let set = try scanner.themes(of: moves, result: .blackWins)
        let rep = try scanner.report(of: moves, result: .blackWins)
        #expect(set == rep.themes)
        #expect(set.rawValue & Theme.smotheredMate.bit(for: .black) != 0)
        #expect(set.ignoringSides & (1 << UInt32(Theme.smotheredMate.rawValue)) != 0)
        let only = ThemeScanner(themes: ThemeSet(.smotheredMate))
        #expect(try only.themes(of: moves) == ThemeSet(.smotheredMate, side: .black))
    }

    @Test func illegalMoveAndBadFENThrow() {
        let scanner = ThemeScanner()
        #expect(throws: ThemeError.illegalMove(index: 0)) {
            try scanner.themes(of: [ThemeMove(uci: "e4e5")!])
        }
        #expect(throws: ThemeError.invalidFEN) {
            try scanner.themes(of: [ThemeMove](), startFEN: "8/8/8 w - - 0 1")
        }
    }

    @Test func blackToMoveFromFENNumbersPliesFromOne() throws {
        let fen = "r3k3/8/8/8/2NN4/8/1q3PPP/6K1 b - - 0 1"
        let r = try report("1...Ra1#", fen: fen, result: .blackWins)
        #expect(r.hit(.matingAttack, side: .black)?.plies == [1])
        #expect(r.hit(.backRankMate, side: .black)?.plies == [1])
        // Dama contra rey solo: mate, pero no ataque de mate (el defensor no tiene piezas).
        let mopUp = try report("1.Qg7#", fen: "7k/8/5K2/8/8/8/8/6Q1 w - - 0 1", result: .whiteWins)
        #expect(!mopUp.themes.contains(.matingAttack))
    }
}

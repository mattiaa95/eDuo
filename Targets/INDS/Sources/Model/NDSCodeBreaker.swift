//
//  NDSCodeBreaker.swift
//  eDuo
//
//  New (no iGBA equivalent). Translates CodeBreaker DS codes — the format
//  Cyber Gadget's CodeFreak DS shares, which is what Japanese code lists
//  and a fair share of English ones are written in — into the Action
//  Replay DS form that melonDS's `AREngine::RunCheat` executes.
//
//  The two formats look identical (pairs of 8-digit hex words) and the
//  engine happily runs either as Action Replay, which is the trap: a
//  CodeBreaker `4XXXXXXX` slider becomes an IF-less-than, its value line a
//  write to address 0x63 (unmapped, silently dropped) and `D4000130` a
//  "bad D4 opcode" — nothing happens and nothing is reported. Worse, the
//  three plain write types are the same digits with the sizes reversed
//  (CodeBreaker 0/1/2 = 8/16/32-bit, Action Replay 0/1/2 = 32/16/8-bit),
//  so a CodeBreaker 8-bit write run as Action Replay clobbers the three
//  bytes after its target.
//
//  Reference: EnHacklopedia, "Codebreaker DS" code types
//  (doc.kodewerx.org/hacking_nds.html), cross-checked against published
//  PAR↔CF conversions of the same codes.
//

import Foundation

enum NDSCodeBreaker {

    typealias Line = (UInt32, UInt32)

    /// A line recognised as CodeBreaker that has no Action Replay
    /// equivalent: boot-up hook writes, pointer writes with an embedded
    /// condition, the two undocumented condition types.
    struct Unsupported: Error, Equatable {
        let line: String
    }

    /// The Action Replay translation of `code`, or nil when `code` is not
    /// CodeBreaker — including when it is a sane Action Replay code.
    /// Action Replay always wins: it is the documented input format, and a
    /// valid code in it must never be reinterpreted.
    static func translate(_ code: [Line]) throws -> [Line]? {
        guard !code.isEmpty, !isSaneActionReplay(code), let items = parse(code) else { return nil }
        return try convert(items)
    }

    static func text(_ line: Line) -> String {
        String(format: "%08X %08X", line.0, line.1)
    }

    // MARK: - Action Replay sanity

    /// True if every line is something melonDS's engine does something
    /// sensible with — writes land in RAM/IO (or follow an offset-setting
    /// code), D-type opcodes have the zero low bytes the format requires,
    /// patch blocks carry their payload — and at least one line has an
    /// effect: a code made only of conditionals does nothing as Action
    /// Replay, so nothing is lost by reading it as CodeBreaker (where
    /// `3…`/`7…` are increments and bitwise writes). CodeBreaker codes
    /// fail this on their value lines (`00000063 00000000` is a write to
    /// address 0x63) or on a conditional such as `D4000130`.
    private static func isSaneActionReplay(_ code: [Line]) -> Bool {
        var offsetMayBeSet = false
        var hasEffect = false
        var i = 0
        while i < code.count {
            let (a, b) = code[i]
            i += 1
            let addr = a & 0x0FFF_FFFF
            switch a >> 28 {
            case 0x0:
                guard offsetMayBeSet || isMemory(addr) else { return false }
                hasEffect = true
            case 0x1:
                guard b <= 0xFFFF, offsetMayBeSet || isMemory(addr) else { return false }
                hasEffect = true
            case 0x2:
                guard b <= 0xFF, offsetMayBeSet || isMemory(addr) else { return false }
                hasEffect = true
            case 0x3...0xA:
                break // conditionals only read
            case 0xB:
                offsetMayBeSet = true
            case 0xC:
                switch a >> 24 {
                case 0xC0, 0xC5: break
                case 0xC6: hasEffect = true
                case 0xC4: offsetMayBeSet = true
                default: return false
                }
            case 0xD:
                let low = a & 0x00FF_FFFF
                switch a >> 24 {
                case 0xD0, 0xD1, 0xD2, 0xD5, 0xD9, 0xDA, 0xDB:
                    guard low == 0 else { return false }
                case 0xD3, 0xDC:
                    guard low == 0 else { return false }
                    offsetMayBeSet = true
                case 0xD6, 0xD7, 0xD8:
                    guard low == 0 else { return false }
                    offsetMayBeSet = true
                    hasEffect = true
                case 0xD4:
                    guard low <= 8 else { return false }
                default:
                    return false // DD–DF: the engine has no such opcode
                }
            case 0xE:
                guard offsetMayBeSet || isMemory(addr) else { return false }
                let payloadLines = Int(b / 8) + (b % 8 == 0 ? 0 : 1)
                guard payloadLines <= code.count - i else { return false }
                i += payloadLines
                hasEffect = true
            case 0xF:
                guard isMemory(addr), b <= 0x10000 else { return false }
                hasEffect = true
            default:
                break
            }
        }
        return hasEffect
    }

    /// Main RAM, WRAM, I/O, VRAM — the regions Action Replay codes write to.
    private static func isMemory(_ addr: UInt32) -> Bool {
        switch addr >> 24 {
        case 0x02, 0x03, 0x04, 0x06, 0x0C: return true
        default: return false
        }
    }

    // MARK: - CodeBreaker grammar

    private enum Instruction {
        case write(size: Int, addr: UInt32, value: UInt32)
        case add(size: Int, addr: UInt32, value: UInt32)
        case slide(size: Int, addr: UInt32, count: Int, step: UInt32, value: UInt32, increment: UInt32)
        case copy(destination: UInt32, source: UInt32, bytes: UInt32)
        case pointerWrite(size: Int, pointer: UInt32, offset: UInt32, value: UInt32)
        case bitwise(op: UInt32, size: Int, addr: UInt32, value: UInt32)
        case condition(lines: Int, test: Line)
        case skip
        case unsupported(Line)
    }

    /// nil when some line does not fit the CodeBreaker grammar at all.
    /// `width` is how many 8-byte lines the instruction occupied — the unit
    /// a conditional's "lines to skip" counts in.
    private static func parse(_ code: [Line]) -> [(Instruction, width: Int)]? {
        var items: [(Instruction, width: Int)] = []
        var i = 0
        while i < code.count {
            let (a, b) = code[i]
            let next: Line? = i + 1 < code.count ? code[i + 1] : nil
            let addr = a & 0x0FFF_FFFF
            var width = 1
            let instruction: Instruction
            switch a >> 28 {
            case 0x0 where b <= 0xFF:
                instruction = .write(size: 1, addr: addr, value: b)
            case 0x0 where a >> 16 == 0:
                instruction = .skip // 0000YYYY XXXXXXXX: game recogniser (header CRC16 + game ID)
            case 0x1 where b <= 0xFFFF:
                instruction = .write(size: 2, addr: addr, value: b)
            case 0x2:
                instruction = .write(size: 4, addr: addr, value: b)
            case 0x3 where a & 0x0800_0000 != 0:
                instruction = .add(size: 4, addr: a & 0x07FF_FFFF, value: b)
            case 0x3 where b >> 17 == 0:
                instruction = .add(size: (b >> 16) & 1 == 1 ? 2 : 1, addr: addr, value: b & 0xFFFF)
            case 0x4:
                guard let pair = next, b >> 28 <= 2 else { return nil }
                instruction = .slide(size: 1 << (2 - Int(b >> 28)), addr: addr, count: Int((b >> 16) & 0xFFF),
                                     step: b & 0xFFFF, value: pair.0, increment: pair.1)
                width = 2
            case 0x5:
                guard let pair = next, pair.1 == 0 else { return nil }
                instruction = .copy(destination: addr, source: pair.0, bytes: b)
                width = 2
            case 0x6:
                guard let pair = next, pair.1 >> 28 <= 2, (pair.1 >> 24) & 0xF <= 1 else { return nil }
                instruction = (pair.1 >> 24) & 0xF == 0
                    ? .pointerWrite(size: 1 << Int(pair.1 >> 28), pointer: addr, offset: pair.0, value: b)
                    : .unsupported((a, b))
                width = 2
            case 0x7 where b >> 24 == 0 && (b >> 20) & 0xF <= 2 && (b >> 16) & 0xF <= 1:
                instruction = .bitwise(op: ((b >> 20) & 0xF) + 1, size: (b >> 16) & 0xF == 1 ? 2 : 1,
                                       addr: addr, value: b & 0xFFFF)
            case 0x8 where a & 0x0FFF_0000 == 0:
                instruction = .skip // 8000YYYY XXXXXXXX: game recogniser of unencrypted lists
            case 0xA:
                instruction = .unsupported((a, b)) // boot-up hook writes
            case 0xD where (b >> 16) & 0xF <= 1:
                if let test = test(addr: addr, type: (b >> 20) & 0xF, byteWide: (b >> 16) & 0xF == 1, value: b & 0xFFFF) {
                    instruction = .condition(lines: max(Int(b >> 24), 1), test: test)
                } else {
                    instruction = .unsupported((a, b))
                }
            case 0xF:
                instruction = .skip // engine hook / (M) master code: an emulator needs none
            default:
                return nil
            }
            items.append((instruction, width))
            i += width
        }
        return items
    }

    /// The Action Replay 16-bit conditional (types 7–A, `TXXXXXXX MMMMVVVV`:
    /// true when VVVV <op> (~MMMM & halfword at XXXXXXX)) equivalent to a
    /// CodeBreaker `DXXXXXXX ZZTUYYYY` test. A byte-wide test is the same
    /// halfword compare with the other byte masked out; the button tests
    /// (T = 4/5, "these bits clear/set") become the familiar
    /// `94000130 FFFB0000` shape.
    private static func test(addr: UInt32, type: UInt32, byteWide: Bool, value: UInt32) -> Line? {
        var address = addr
        var mask: UInt32 = 0
        var value = value
        if byteWide {
            value &= 0xFF
            if address & 1 == 1 {
                value <<= 8
                mask = 0x00FF
                address &= ~1
            } else {
                mask = 0xFF00
            }
        }
        let opcode: UInt32
        switch type {
        case 0: opcode = 0x9 // ==
        case 1: opcode = 0xA // !=
        case 2: opcode = 0x7 // memory < value, i.e. value > memory
        case 3: opcode = 0x8 // memory > value
        case 4, 5:           // (memory & value) == 0  /  != 0
            mask = ~value & 0xFFFF
            value = 0
            opcode = type == 4 ? 0x9 : 0xA
        default:
            return nil
        }
        return ((opcode << 28) | (address & 0x0FFF_FFFF), (mask << 16) | value)
    }

    // MARK: - Emission

    /// Each instruction becomes a self-contained block: the test of every
    /// enclosing CodeBreaker conditional, the body, and — whenever the body
    /// touched the offset/data registers or ran under a test — a D2
    /// (NEXT + flush). melonDS executes D2 even while a condition is false,
    /// so the block always closes what it opened, and it is also what ends
    /// a slider's C0 loop. Repeating the tests per block costs a few reads
    /// per frame and buys freedom from D1's quirk (a NEXT with no loop
    /// running restores the *initial* condition, i.e. re-enables a block
    /// that should have stayed skipped).
    private static func convert(_ items: [(Instruction, width: Int)]) throws -> [Line] {
        var out: [Line] = []
        var active: [(test: Line, remaining: Int)] = []
        for (instruction, width) in items {
            let tests = active.map(\.test)
            func emit(_ body: [Line], flush: Bool) {
                guard !body.isEmpty else { return }
                out += tests
                out += body
                if flush || !tests.isEmpty { out.append((0xD200_0000, 0)) }
            }
            switch instruction {
            case .write(let size, let addr, let value):
                emit([(writeOpcode(size) | addr, value)], flush: false)
            case .add(let size, let addr, let value):
                emit([(loadOpcode(size), addr), (0xD400_0000, value), (storeOpcode(size), addr)], flush: true)
            case .slide(let size, let addr, let count, let step, let value, let increment):
                guard count > 0 else { break }
                var body: [Line] = [(0xD300_0000, addr), (0xD500_0000, value),
                                    (0xC000_0000, UInt32(count - 1)), (storeOpcode(size), 0)]
                if step != 1 { body.append((0xDC00_0000, (step &- 1) &* UInt32(size))) }
                if increment != 0 { body.append((0xD400_0000, increment)) }
                emit(body, flush: true)
            case .copy(let destination, let source, let bytes):
                emit([(0xD300_0000, source), (0xF000_0000 | destination, bytes)], flush: true)
            case .pointerWrite(let size, let pointer, let offset, let value):
                emit([(0xB000_0000 | pointer, 0), (0xDC00_0000, offset), (writeOpcode(size), value)], flush: true)
            case .bitwise(let op, let size, let addr, let value):
                emit([(loadOpcode(size), addr), (0xD400_0000 | op, value), (storeOpcode(size), addr)], flush: true)
            case .condition, .skip:
                break
            case .unsupported(let line):
                throw Unsupported(line: text(line))
            }
            for k in active.indices { active[k].remaining -= width }
            active.removeAll { $0.remaining <= 0 }
            if case .condition(let lines, let test) = instruction {
                active.append((test, lines))
            }
        }
        return out
    }

    private static func writeOpcode(_ size: Int) -> UInt32 {
        size == 4 ? 0x0000_0000 : size == 2 ? 0x1000_0000 : 0x2000_0000
    }

    /// D6/D7/D8: write the data register at `offset`, then advance it.
    private static func storeOpcode(_ size: Int) -> UInt32 {
        size == 4 ? 0xD600_0000 : size == 2 ? 0xD700_0000 : 0xD800_0000
    }

    /// D9/DA/DB: load the data register.
    private static func loadOpcode(_ size: Int) -> UInt32 {
        size == 4 ? 0xD900_0000 : size == 2 ? 0xDA00_0000 : 0xDB00_0000
    }
}

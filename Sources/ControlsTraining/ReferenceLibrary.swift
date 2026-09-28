import Foundation

/// A structured, offline reference library covering Rockwell / Allen-Bradley control
/// hardware, networks, instrumentation, the ladder instruction set, drives, and
/// functional safety. Content is condensed from the Logix 5000 Field Manual so it
/// can be browsed inside the trainer without leaving the app.
public struct ReferenceArticle: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var summary: String
    public var systemImage: String
    public var readMinutes: Int
    public var sections: [Section]

    public struct Section: Identifiable, Equatable, Sendable {
        public let id: String
        public var heading: String
        public var blocks: [Block]
        public init(_ id: String, _ heading: String, _ blocks: [Block]) {
            self.id = id; self.heading = heading; self.blocks = blocks
        }
    }

    public enum Block: Equatable, Sendable {
        case text(String)
        case bullets([String])
        case mono(String)
        case table(headers: [String], rows: [[String]])
        case note(String)
        case caution(String)
        case field(String)
    }

    public init(id: String, title: String, summary: String, systemImage: String, readMinutes: Int, sections: [Section]) {
        self.id = id; self.title = title; self.summary = summary
        self.systemImage = systemImage; self.readMinutes = readMinutes; self.sections = sections
    }
}

public enum ReferenceTopic: String, CaseIterable, Identifiable, Sendable {
    case hardware = "Controllers & Hardware"
    case io = "I/O & Instrumentation"
    case networks = "Communications"
    case programming = "Programming"
    case drives = "Motor Control & Drives"
    case safety = "Functional Safety"

    public var id: String { rawValue }
    public var systemImage: String {
        switch self {
        case .hardware: "cpu"
        case .io: "cable.connector"
        case .networks: "network"
        case .programming: "chevron.left.forwardslash.chevron.right"
        case .drives: "bolt.circle"
        case .safety: "shield.lefthalf.filled"
        }
    }
}

public enum ReferenceLibrary {
    public static func articles(in topic: ReferenceTopic) -> [ReferenceArticle] {
        all.filter { articleTopic($0.id) == topic }
    }

    public static func article(_ id: String) -> ReferenceArticle? { all.first { $0.id == id } }

    public static func articleTopic(_ id: String) -> ReferenceTopic {
        switch id {
        case "scan-model", "chassis-controllers": .hardware
        case "io-modules", "instrumentation": .io
        case "networks": .networks
        case "instruction-set": .programming
        case "vfd-motor-control": .drives
        case "functional-safety": .safety
        default: .programming
        }
    }

    public static let all: [ReferenceArticle] = [
        scanModel, chassisControllers, ioModules, networks, instrumentation,
        instructionSet, vfdMotorControl, functionalSafety
    ]

    // MARK: - The Logix scan & task model

    static let scanModel = ReferenceArticle(
        id: "scan-model",
        title: "The PLC & the Logix Scan",
        summary: "How Logix replaces the classic single scan loop with a small real-time operating system of tasks.",
        systemImage: "arrow.triangle.2.circlepath",
        readMinutes: 6,
        sections: [
            .init("classic", "The classic scan cycle", [
                .text("A legacy controller (SLC, PLC-5, MicroLogix) repeats four phases forever:"),
                .bullets([
                    "Input scan — copy physical input terminals into the input image table. Logic reads the image, not the terminal.",
                    "Program scan — solve every rung top to bottom, left to right; write results to the output image table.",
                    "Output scan — copy the output image to the physical output terminals.",
                    "Housekeeping — service communications, diagnostics, the watchdog, the serial port."
                ]),
                .text("Consequences: an input that pulses between input scans is never seen; an output written by two rungs takes the value of the last rung solved (dual-coil)."),
            ]),
            .init("tasks", "The Logix model: tasks, not one loop", [
                .text("Logix 5000 has no fixed I/O image table. Modules exchange data on their own schedule — the Requested Packet Interval (RPI) — asynchronous to program execution. Logic operates on tags; I/O tags refresh in the background."),
                .text("User code lives in tasks:"),
                .bullets([
                    "Continuous task — exactly one; restarts the instant it finishes, in whatever time higher-priority tasks leave it.",
                    "Periodic tasks — run on a fixed time base at priority 1 (highest) to 15; interrupt the continuous task and lower-priority periodic tasks. Almost all machine logic belongs here.",
                    "Event tasks — run on a trigger: an input module change of state, a consumed-tag update, a motion-group execution, an axis registration/watch, or an EVENT instruction."
                ]),
                .text("A 5580 supports up to 32 tasks total. If a periodic task is still running when its next trigger arrives, that is an overlap — logged as a minor fault, then a major fault past a threshold."),
            ]),
            .init("prescan", "Prescan, first scan, watchdog", [
                .bullets([
                    "Prescan — a one-time pass on the Program → Run transition; clears non-retentive outputs and one-shot storage bits. Does not run timers or counters.",
                    "First scan — S:FS (or Controller:FirstScan) is true for the first normal execution only; use it to initialize setpoints and state.",
                    "Watchdog — each task has one (default 500 ms). Exceed it (infinite loop, blocked message) and the controller faults Type 6 Code 1 and drops to Program with outputs off."
                ]),
                .field("Put all control logic in periodic tasks — a fast task (5–10 ms) for interlocks and E-stop response, a medium task (20–50 ms) for sequencing, a slow task (100–250 ms) for analog and PID, and the continuous task for diagnostics and HMI support. Scan time then becomes predictable."),
            ]),
            .init("io-timing", "I/O timing you must reason about", [
                .bullets([
                    "RPI is how often a module sends data, not how often logic uses it. A 2 ms RPI on a 100 ms task just adds network load.",
                    "Input-to-output latency ≈ input RPI + task period + output RPI + module filter times. For a fast interlock use a fast task and fast RPI and a low input filter — or an event task.",
                    "Connection timeout = RPI × multiplier (default 4×, min 100 ms). Lose that many packets and the connection faults; input tags hold last value and Module:I.ConnectionFaulted goes true. Your logic must check that bit.",
                    "CIP Sync (IEEE 1588 PTP) time-stamps events at the module — the basis of sequence-of-events recording and CIP Motion."
                ]),
            ]),
        ]
    )

    // MARK: - Chassis, controllers & power

    static let chassisControllers = ReferenceArticle(
        id: "chassis-controllers",
        title: "Chassis, Controllers & Power",
        summary: "ControlLogix is modular — a chassis, a power supply, controllers and modules in any slot. CompactLogix collapses it onto a DIN rail.",
        systemImage: "cpu",
        readMinutes: 7,
        sections: [
            .init("families", "The Logix 5000 controller families", [
                .table(headers: ["Family", "Catalog", "Form factor"], rows: [
                    ["ControlLogix 5580", "1756-L8xE", "1756 modular chassis"],
                    ["ControlLogix 5570", "1756-L7x", "1756 chassis, uses an Energy Storage Module"],
                    ["GuardLogix 5580", "1756-L8xES / EP", "Integrated SIL 3 / PLe safety + standard control"],
                    ["GuardLogix 5570", "1756-L7xS + 1756-L7SP", "Safety controller + separate safety partner"],
                    ["CompactLogix 5380", "5069-L3x(ERM)(S)", "DIN-rail with local I/O bank"],
                    ["CompactLogix 5480", "5069-L4x", "DIN-rail + on-board Windows 10 IoT core"],
                    ["CompactLogix 5370", "1769-L1/L2/L3x", "Previous generation, 1769 Compact I/O"],
                ]),
                .note("\"5580\" and \"1756-L8x\" are the same controller — one is the marketing name, the other the catalog stem. RSLogix 5000 (v20 and earlier) and Studio 5000 Logix Designer (v21+) are the same tool renamed."),
            ]),
            .init("chassis", "1756 chassis & power", [
                .text("The chassis is a passive backplane with a fixed slot count, numbered left to right from 0. The power supply clips to the left end and does not use a slot. Any module in any slot."),
                .table(headers: ["Chassis", "Slots"], rows: [
                    ["1756-A4", "4"], ["1756-A7", "7"], ["1756-A10", "10"], ["1756-A13", "13"], ["1756-A17", "17"],
                ]),
                .text("Power supplies convert line power to the backplane rails (they do not power field I/O): 1756-PA72 / PB72 (standard AC / 24 V DC), PA75 / PB75 (high capacity), PC75 (125 V DC), PH75 (48 V DC), and redundant PA75R / PB75R with a 1756-PSCA2 adapter. Fill empty slots with a 1756-N2 filler."),
            ]),
            .init("controllers", "5580 and 5570 controllers", [
                .bullets([
                    "5580 (1756-L8x): L81E (3 MB) … L85E (40 MB); one or two Gigabit EtherNet/IP ports on board, a USB port, an SD card slot, a supercapacitor-backed real-time clock. No battery.",
                    "5570 (1756-L7x): L71 (2 MB) … L75 (32 MB); Ethernet is NOT on the controller (add a 1756-EN2T). Uses an Energy Storage Module (1756-ESMCAP) instead of a battery — pulling the ESM from a powered running controller clears its memory after the hold-up time.",
                    "Nonvolatile memory: an SD card holds the project image; configure Load Image On Power Up / On Corrupt Memory / User Initiated."
                ]),
            ]),
            .init("redundancy", "Redundancy & CompactLogix", [
                .text("ControlLogix redundancy: two identical chassis, each with a controller and a 1756-RM2 module linked by fiber. The primary crossloads tag values every scan; on a fault the secondary takes over bumplessly within 1–3 scans. Only EtherNet/IP and ControlNet modules belong in the redundant chassis; I/O lives in remote chassis reachable from both."),
                .text("CompactLogix 5380: no chassis. The controller needs external 24 V DC and forms the left end of a bank; 5069 I/O modules snap on to its right and the bank ends with a 5069-ARM terminator. The 5480 adds an Intel CPU running Windows 10 IoT beside the real-time core."),
                .caution("Electronic keying: choose Exact Match (catalog + firmware must match), Compatible Module (the usual choice), or Disable Keying (any module that fits will connect — dangerous, an output module can replace an input and the controller still runs)."),
            ]),
        ]
    )

    // MARK: - I/O modules

    static let ioModules = ReferenceArticle(
        id: "io-modules",
        title: "I/O Modules & Catalog Numbers",
        summary: "The catalog number tells you almost everything: 1756- then Input/Output, a signal-class letter, the point count, then feature letters.",
        systemImage: "cable.connector",
        readMinutes: 7,
        sections: [
            .init("decode", "Decoding 1756 I/O", [
                .text("1756- + I(nput) or O(utput) + signal-class letter + point count + feature letters. 1756-OB16E = output, 24 V DC (B), 16 points, electronically protected (E)."),
                .table(headers: ["Letter", "Signal"], rows: [
                    ["A", "120 V AC"], ["M", "240 V AC"],
                    ["B", "24 V DC, sinking input / sourcing output"],
                    ["V", "24 V DC, sourcing input / sinking output"],
                    ["N", "10–30 V AC/DC"], ["H", "125 V DC"],
                    ["W / X", "relay (dry) output — W = 2 A, X = 5 A form C"],
                    ["F", "analog current/voltage"], ["R", "RTD input"], ["T", "thermocouple / mV input"],
                ]),
                .text("Feature suffixes: D = per-point diagnostics, I = individually isolated, E = electronic output protection, F = fast / CIP Sync timestamped, H = HART, ISOE = isolated sequence-of-events, K = conformal coat, XT = extreme temperature."),
            ]),
            .init("sinksource", "Sinking vs sourcing", [
                .bullets([
                    "A sinking input (1756-IB x) expects the field device to supply +24 V; the module provides the return. Pairs with a sourcing / PNP sensor.",
                    "A sourcing input (1756-IV x) supplies +24 V from the module; the field device switches the point to 0 V. Pairs with a sinking / NPN sensor.",
                    "Standardize the plant on PNP sensors + sinking inputs and the question disappears."
                ]),
                .caution("Solid-state AC outputs have off-state leakage that can hold a small pilot or relay on — add a bleeder or use a relay output. Inductive DC loads need a flyback diode or the output's protection trips."),
            ]),
            .init("analog", "Analog modules", [
                .table(headers: ["Catalog", "Type", "Ch"], rows: [
                    ["1756-IF8 / IF16", "Voltage / current in", "8 / 16"],
                    ["1756-IF8I", "Isolated V/I in", "8"],
                    ["1756-IF8H", "V/I + HART in", "8"],
                    ["1756-IR6I", "Isolated RTD", "6"],
                    ["1756-IT6I / IT6I2", "Isolated thermocouple / mV", "6"],
                    ["1756-OF4 / OF8", "Voltage & current out", "4 / 8"],
                    ["1756-OF8I / OF6CI / OF6VI", "Isolated output", "8 / 6 / 6"],
                ]),
                .text("Configure each channel's electrical range, the scaling (Low/High signal → Low/High engineering, so the module delivers a REAL in units), RTS (conversion interval), a digital filter and notch filter, per-channel alarms, and — critically — the hold-last vs go-to-safe-value behavior for connection loss and Program mode. For 4–20 mA, open-wire detection (< ~3.2 mA) surfaces as a status bit your logic must use."),
            ]),
            .init("platforms", "Remote & distributed I/O", [
                .table(headers: ["Platform", "Adapter", "Use"], rows: [
                    ["1756 ControlLogix I/O", "1756-EN2T/EN2TR", "Large drops, HART, isolated analog"],
                    ["5069 Compact 5000 I/O", "5069-AEN2TR", "Current-gen distributed I/O, safety modules"],
                    ["1734 POINT I/O", "1734-AENT/AENTR, -ADN", "Small drops, 1-point granularity, POINT Guard safety"],
                    ["1794 FLEX I/O", "1794-AENT/AENTR, -ACN15", "Field-wiring friendly, FLEX Ex for hazardous areas"],
                    ["1732 ArmorBlock", "integrated EtherNet/IP", "On-machine, IP67, no enclosure"],
                    ["1715 Redundant I/O", "1715-AENTR pair", "Redundant I/O without controller redundancy"],
                ]),
                .field("Never write logic against raw Local:x:I.Data.y. Alias every I/O point to a plant name (Conveyor_1_Run_Cmd) and program against the alias — one place to change if the module moves."),
            ]),
        ]
    )

    // MARK: - Networks

    static let networks = ReferenceArticle(
        id: "networks",
        title: "Industrial Networks & CIP",
        summary: "Everything Rockwell rides on CIP — the Common Industrial Protocol. Learn CIP once and every network is the same conversation on different wire.",
        systemImage: "network",
        readMinutes: 8,
        sections: [
            .init("cip", "Two kinds of CIP message", [
                .bullets([
                    "Implicit (I/O) — \"Class 1\" connected messaging. Cyclic, time-critical, sent at the RPI, small, no application acknowledgement. I/O modules, produced/consumed tags, drives. On Ethernet uses UDP.",
                    "Explicit — \"Class 3\" or UCMM request/response. The MSG instruction, HMI reads, programming software, device configuration. On Ethernet uses TCP (port 44818)."
                ]),
            ]),
            .init("enip", "EtherNet/IP", [
                .table(headers: ["Catalog", "Ports", "Role"], rows: [
                    ["1756-EN2T", "1 × 10/100", "The long-time standard, ~256 CIP connections"],
                    ["1756-EN2TR", "2 × 10/100", "Dual-port for Device-Level Ring or linear"],
                    ["1756-EN4TR", "2 × 10/100/1000", "Gigabit, more connections, CIP Security"],
                    ["1756-EN2F", "1 × 100 fiber", "Long runs, heavy noise, ground isolation"],
                ]),
                .text("5580 and 5380 have EtherNet/IP on board — a small system may need no comm module. Topologies: star (managed switch, the default), linear (daisy-chain), Device-Level Ring (a ring with a supervisor that recovers a cable break in < 3 ms), and redundant star / PRP (two parallel infrastructures, zero-loss failover)."),
                .caution("On a control network, managed-switch features are not optional. IGMP snooping + one querier per VLAN keeps multicast I/O from flooding every port — the #1 cause of \"the network was fine for months then everything faulted.\" Also QoS, port security, DHCP persistence, and VLANs."),
            ]),
            .init("legacy", "ControlNet & DeviceNet", [
                .bullets([
                    "ControlNet — deterministic 5 Mbps on RG-6 coax. Time slots of the Network Update Time (2–100 ms) split into scheduled (guaranteed) and unscheduled bandwidth. Node 1–99, 75 Ω terminators, taps at every node, redundant channels A/B. The schedule lives in a \"keeper\" (lowest-address CNB); replace that node without the schedule and the whole network drops (keeper crash).",
                    "DeviceNet — CAN-based device bus, up to 64 nodes (MAC ID 0–63), 24 V DC network power on the cable. 500 kbps @ 100 m, 250 @ 250 m, 125 @ 500 m. 121 Ω terminators at both ends. Scanner = 1756-DNB with a scan list, configured in RSNetWorx with the device's EDS file."
                ]),
            ]),
            .init("bridges", "Legacy serial & foreign networks", [
                .table(headers: ["Network", "Bridge into Logix"], rows: [
                    ["DH+ / Remote I/O", "1756-DHRIO module; MSG type PLC5/SLC"],
                    ["DF1 / Modbus RTU", "CompactLogix serial port, or a Prosoft gateway"],
                    ["Modbus TCP", "Prosoft / HMS gateway, or MSG CIP-generic + socket object"],
                    ["PROFIBUS / PROFINET", "Prosoft or HMS Anybus gateway presenting the data as EtherNet/IP"],
                    ["OPC UA", "Embedded server on 5380/5480/5580, or FactoryTalk Linx Gateway"],
                ]),
            ]),
            .init("pcmsg", "Produced/consumed tags & MSG", [
                .text("Produced/consumed: one controller marks a controller-scoped tag Produced; another marks a matching tag Consumed at a chosen RPI. Data updates cyclically like I/O — no MSG. Keep the payload small (a UDT of the few signals that must be shared)."),
                .text("The MSG instruction is one rung-triggered transfer: choose the type (CIP Data Table Read/Write, CIP Generic, PLC5/SLC, Block-Transfer), the path, and whether to cache the connection. Coding pattern: one-shot the trigger; watch .DN / .ER; don't re-fire until the last one finishes; on .ER read .ERR / .EXERR and retry with backoff."),
                .field("Don't build a plant on hundreds of MSG instructions polling each other. Use produced/consumed for anything cyclic; reserve MSG for events, recipes, and diagnostics."),
            ]),
        ]
    )

    // MARK: - Instrumentation

    static let instrumentation = ReferenceArticle(
        id: "instrumentation",
        title: "Instrumentation & Field Devices",
        summary: "The analog and discrete field world — current loops, RTDs and thermocouples, sensors, encoders. Most \"PLC problems\" are wiring, grounding, or a wrong signal type.",
        systemImage: "sensor",
        readMinutes: 8,
        sections: [
            .init("loop", "The 4–20 mA current loop", [
                .text("The dominant analog standard because current does not drop with wire length or resistance — the same 12.00 mA arrives whether the transmitter is 3 m or 800 m away. The live zero (4 mA = 0%) means a broken wire reads ~0 mA, which the module flags as a fault."),
                .table(headers: ["Type", "How it's powered"], rows: [
                    ["2-wire (loop powered)", "The 4–20 mA loop powers the transmitter; simplest, limited power budget"],
                    ["3-wire", "Separate +24 V and 0 V power the transmitter; a third wire carries the signal"],
                    ["4-wire", "Fully independent power and an isolated signal pair; best isolation"],
                ]),
                .bullets([
                    "Decide once whether the module or an external supply provides loop power — double-powered loops fight and read wrong.",
                    "Voltage signals (0–10 V, ±10 V) DO lose accuracy over distance and pick up noise — keep runs short, prefer current."
                ]),
            ]),
            .init("scaling", "Scaling raw counts to engineering units", [
                .text("An analog input converts the electrical signal to a raw number. Enter the electrical and engineering ranges in the module's Scaling tab and it hands you a REAL in units. If you must scale in logic:"),
                .mono("EU = (Raw - RawLo) * (EuHi - EuLo) / (RawHi - RawLo) + EuLo"),
                .text("Do it with CPT or an AOI, clamp the result, and drive a \"bad PV\" flag from the module's underrange / overrange / open-wire status so the PID holds last value instead of acting on a pinned reading."),
            ]),
            .init("temp", "Temperature measurement", [
                .bullets([
                    "RTD — a precision resistor whose resistance rises with temperature. Pt100 is standard. 2-wire adds the wire's resistance to the reading; 3-wire subtracts one lead; 4-wire cancels lead resistance entirely — use 4-wire for anything precise or far away.",
                    "Thermocouple — two dissimilar metals generate µV–mV proportional to the temperature difference between the measuring and terminal (cold) junctions. Type K (chromel/alumel) is the general default; J for lower ranges; R/S/B (platinum) for kilns.",
                    "Cold-junction compensation — the module measures its own terminal temperature and adds it back. A wrong or disabled CJC gives a reading that swings with panel temperature.",
                    "Extend a thermocouple with matching / compensating wire only — copper extension wire adds a second junction and a bias. Open-thermocouple detection pins the reading upscale so a burned-out couple trips a high alarm."
                ]),
            ]),
            .init("sensors", "Discrete sensors & feedback", [
                .table(headers: ["Sensor", "Senses"], rows: [
                    ["Inductive proximity", "Metal at a few mm; rated distance is for mild steel"],
                    ["Capacitive proximity", "Almost anything — liquid, powder, plastic, through a wall"],
                    ["Photoelectric (through-beam / retro / diffuse)", "Object breaking or returning a light beam"],
                    ["Incremental encoder", "A/B quadrature pulses + Z marker; loses position on power-down (needs homing)"],
                    ["Absolute encoder", "Actual shaft angle at power-up; SSI, BiSS, or native EtherNet/IP"],
                    ["Hiperface DSL", "Absolute servo feedback on the same cable as motor power"],
                ]),
                .text("PNP output switches the load to +24 V (use with sinking inputs); NPN switches to 0 V (use with sourcing inputs). Choose the combination so \"object present\" = \"input on.\""),
                .caution("Shield drain wires land at one end only (the panel end). Route analog and comm cable in separate wireways from AC power and VFD output cable. A reading that hums at line frequency, jumps when a motor starts, or drifts with panel temperature is a shield, a ground loop, or a common-mode voltage — not a bad transmitter."),
            ]),
        ]
    )

    // MARK: - Instruction set

    static let instructionSet = ReferenceArticle(
        id: "instruction-set",
        title: "The Ladder Instruction Set",
        summary: "A working reference to the Logix 5000 instruction families, their timing behavior, and the trap that catches people. The authoritative source is publication 1756-RM003.",
        systemImage: "chevron.left.forwardslash.chevron.right",
        readMinutes: 10,
        sections: [
            .init("bit", "Bit instructions", [
                .table(headers: ["Mnemonic", "Behavior"], rows: [
                    ["XIC", "True when the bit = 1 (\"is this on?\")"],
                    ["XIO", "True when the bit = 0 (\"is this off?\" / NOT)"],
                    ["OTE", "Sets the bit to rung-condition-in every scan. Not retentive. EXACTLY ONE per bit."],
                    ["OTL / OTU", "Latch to 1 / clear to 0 and hold. Retentive. Always design the matching unlatch."],
                    ["ONS", "Passes true for one scan on the false→true edge; needs a unique storage bit."],
                    ["OSR / OSF", "Output-side one-shots — set an Output Bit true for one scan on the rising / falling edge."],
                ]),
                .caution("Dual-coil: the same bit as the target of two OTEs — the last rung solved wins and the output \"flickers.\" Cross-reference the tag. Each bit gets exactly one OTE; use OTL/OTU or restructure if two conditions must drive it."),
            ]),
            .init("timers", "Timers & counters", [
                .text("Timers use a TIMER structure (.PRE, .ACC, .EN, .TT, .DN), time base 1 ms. Accuracy is one scan of the routine holding the timer — put fast timers in a fast task."),
                .table(headers: ["Mnemonic", "Behavior"], rows: [
                    ["TON", "Times up while the rung is true; .DN at .ACC ≥ .PRE; resets to 0 when the rung goes false"],
                    ["TOF", "Times up while the rung is false; .DN true immediately on true, drops after .PRE once false"],
                    ["RTO", "Like TON but .ACC HOLDS when the rung goes false; only RES clears it"],
                    ["CTU / CTD", "±1 per false→true edge of the rung; .DN latches at preset but keeps counting; RES zeroes it"],
                ]),
                .caution("A timer whose rung is jumped over freezes — .ACC stops and .DN never changes. A CTU can only register one count per scan; use a high-speed counter module for fast pulses."),
            ]),
            .init("mathmove", "Compare, math & move", [
                .bullets([
                    "Compare (input): EQU NEQ LES GRT LEQ GEQ, plus LIM (band test, inverted if Low > High) and MEQ (masked equal).",
                    "Math: ADD SUB MUL DIV MOD ABS SQR NEG; CPT evaluates one full expression into a destination. Integer DIV truncates (7/2 = 3); overflow wraps and sets S:V; DIV by zero faults.",
                    "Move: MOV (with type conversion), MVM (masked move), CLR, BTD (bit-field distribute), SWPB (byte swap), and the bitwise AND OR XOR NOT.",
                    "GSV / SSV read and write controller object attributes — WALLCLOCKTIME, TASK, MODULE health, FAULTLOG, MESSAGE path."
                ]),
                .field("Put .0 on constants (7.0 / 2) to force REAL math. One CPT replaces a chain of MUL/ADD rungs — clearer and atomic."),
            ]),
            .init("arrayprog", "Array, file & program control", [
                .bullets([
                    "COP copies elements of the DESTINATION type with no conversion; CPS is the uninterruptible version — use it when copying a UDT another task or the HMI also touches.",
                    "FAL / FSC apply an expression / compare across an array; in ALL mode over a big array they can blow the watchdog — use INC or numeric mode.",
                    "BSL / BSR shift a bit array one position per edge (a tracking shift register); FFL/FFU and LFL/LFU are FIFO / LIFO queues.",
                    "JSR / SBR / RET call routines with parameters; JMP/LBL skip rungs (their outputs go false, timers freeze); MCR brackets a de-energize zone (NOT a safety function); AFI forces a rung false for commissioning."
                ]),
            ]),
            .init("pid", "Process & the PID instruction", [
                .text("PID (available in ladder) reads a process variable, compares to a setpoint, and drives a control variable. Key members: .SP, .PV, .CV; gains as Independent (.KP, .KI 1/sec, .KD sec) or Dependent/ISA (.KP controller gain, .KI min/repeat, .KD min); .CA control action (direct = heating, reverse = cooling); .MAXO/.MINO anti-windup; .DB deadband; feed-forward via .BIAS/.FF."),
                .caution(".UPD (loop update time) must match how often the instruction is scanned — put the PID in a periodic task whose period equals .UPD, or the integral and derivative math is wrong. For more than a couple of loops, use PIDE (function block: velocity form, autotune, gain scheduling, faceplate)."),
            ]),
            .init("motionsafety", "Motion & safety instructions", [
                .bullets([
                    "Motion (CIP Motion): MSO/MSF servo on/off, MAM move, MAJ jog, MAS stop, MAH home, MAG gear, MCD change dynamics, MAPC/MATC cam, MCLM/MCCM coordinated interpolation. Queued to a Motion Group with a 1–4 ms coarse update period.",
                    "Safety (GuardLogix safety task, TÜV-certified): ESTOP, DCS/DCM dual-channel stop/monitor, RIN monitored reset, THRS two-hand, LC light curtain, SMAT mat, ROUT/CROUT redundant output with feedback. Every one is: two input channels → agree within a discrepancy time → require a monitored reset → expose fault codes."
                ]),
            ]),
        ]
    )

    // MARK: - VFDs & motor control

    static let vfdMotorControl = ReferenceArticle(
        id: "vfd-motor-control",
        title: "Motor Control & VFDs",
        summary: "From a bare contactor to a regenerative drive. PowerFlex and Kinetix devices become EtherNet/IP nodes the controller commands like an I/O point.",
        systemImage: "bolt.circle",
        readMinutes: 9,
        sections: [
            .init("basics", "Motor & starting basics", [
                .bullets([
                    "Synchronous speed = 120 × frequency ÷ poles. An induction motor runs slightly slower — the difference (slip) produces torque.",
                    "Change speed by changing frequency; keep volts-per-hertz roughly constant to base speed, then hold voltage (field weakening) above it.",
                    "Starting methods cheapest to most capable: across-the-line (contactor + overload) → reduced-voltage / soft start → VFD.",
                    "Overload trip class: Class 10 trips in ≤ 10 s (general); Class 20/30 for high-inertia loads. Set the dial to motor FLA."
                ]),
                .text("Contactors & overloads: Bulletin 100-C contactors, 100S-C safety contactors (mirrored contacts), E1 Plus / E100 / E200 / E300 electronic overloads. The E300 is a modular networked motor controller — an EtherNet/IP node reporting amps, voltage, power, %thermal, and trip history."),
            ]),
            .init("softstart", "Soft starters (SMC)", [
                .text("SCR phase-control ramps voltage (hence current and torque) up over a set time — reduces inrush and mechanical shock but gives no speed control. A bypass contactor shorts the SCRs once at speed. Good for pumps, fans, compressors."),
                .table(headers: ["Family", "Notes"], rows: [
                    ["SMC-3", "Compact, basic soft start / stop, built-in bypass"],
                    ["SMC Flex", "Current limit, dual ramp, pump control (anti-water-hammer), braking, metering, network option"],
                    ["SMC-50", "Modular, higher power, adaptive control, EtherNet/IP"],
                ]),
            ]),
            .init("vfdtheory", "How a VFD works", [
                .bullets([
                    "Rectifier converts incoming AC to DC (6-pulse diode bridge, or 12/18-pulse, or an active front end).",
                    "DC bus — capacitors smooth and store; bus voltage ≈ 1.35 × line (~650 V DC on a 480 V drive).",
                    "Inverter — six IGBTs switched by PWM at a 2–16 kHz carrier synthesize a variable-voltage variable-frequency output."
                ]),
                .table(headers: ["Control mode", "Use"], rows: [
                    ["Volts/Hz (V/Hz)", "Fans, pumps, multi-motor; simplest, least low-speed torque"],
                    ["Sensorless Vector (SVC)", "General machinery; good low-speed torque without an encoder"],
                    ["Flux Vector / FVC (closed loop)", "Hoists, winders, positioning — full torque at standstill"],
                    ["Permanent Magnet / SynRM", "High-efficiency retrofits, smaller frame"],
                ]),
            ]),
            .init("appeng", "Application engineering", [
                .bullets([
                    "Regeneration — an overhauling load pushes energy back into the DC bus, raising its voltage. Options: a dynamic brake resistor, a regenerative front end (PowerFlex 755TR), or a common DC bus.",
                    "Output-side: fast IGBT edges + long motor cable cause reflected-wave voltage doubling at the motor and common-mode bearing currents. Mitigate with output reactors, dV/dt or sine filters, shaft grounding, inverter-duty motors; observe the max cable length.",
                    "Input-side (harmonics): a 6-pulse rectifier draws distorted current. Mitigate with a line reactor (3–5%), 12/18-pulse, a passive filter, or an active front end. Utilities hold you to IEEE 519.",
                    "Configure motor overload (I²t to FLA), current limit, DC-bus ride-through, and the fault action on a comms loss (coast, ramp, hold, or run at a fallback speed)."
                ]),
            ]),
            .init("powerflex", "The PowerFlex family", [
                .table(headers: ["Drive", "Class"], rows: [
                    ["PowerFlex 4 / 4M / 40 / 400", "Micro to compact V/Hz + SVC (40P adds indexing)"],
                    ["PowerFlex 525", "Compact, embedded dual-port EtherNet/IP, safety STO, V/Hz + SVC + closed loop"],
                    ["PowerFlex 527", "EtherNet/IP-only, designed as an induction/PM axis on a Logix motion group"],
                    ["PowerFlex 753 / 755", "Architecture-class: option slots for I/O, feedback, safety, comms; 755 has embedded DLR EtherNet/IP + PM & FVC"],
                    ["PowerFlex 755T", "TotalFORCE: low-harmonic (TL), regenerative (TR), common-bus (TM)"],
                    ["PowerFlex 6000 / 7000", "Medium voltage, 2.3–11 kV"],
                ]),
                .text("750-series option cards (20-750-…): ENETR (dual-port DLR), UFB-1 (universal feedback), S1 (STO to SIL 3), S3 (DriveGuard safe speed monitor — SS1, SS2, SOS, SLS). DPI peripherals: the HIM keypad, comm cards. Datalinks map up to 16 extra parameters into the cyclic data so logic sees live current / power / frequency without a MSG. Automatic Device Configuration (ADC) pushes the full parameter set to a replacement drive on connection."),
            ]),
            .init("servo", "Kinetix servo & when to use it", [
                .text("When you need coordinated, precise, dynamic motion — positioning, gearing, camming, interpolation, robotics — move from a VFD to a servo: a Kinetix drive + a feedback motor, configured as an axis on a Logix Motion Group. Modern Rockwell motion is CIP Motion over EtherNet/IP — the drive is a standard node, no motion module."),
                .table(headers: ["Drive", "Notes"], rows: [
                    ["Kinetix 5100", "Single-axis, runs standalone like a VFD OR as a full CIP Motion axis"],
                    ["Kinetix 5300 / 5500", "Multi / single-axis EtherNet/IP CIP Motion, integrated STO"],
                    ["Kinetix 5700", "Multi-axis shared DC bus, regenerative supply, integrated CIP Safety (STO, SS1, SS2, SLS)"],
                    ["Kinetix 6000 / 6500", "Power-rail multi-axis (SERCOS / EtherNet/IP), large installed base"],
                ]),
                .field("PowerFlex 527 and Kinetix 5100 deliberately straddle the line — an induction motor on a motion group, or a servo drive that behaves like a VFD — for applications that need some coordination without full servo cost. Fault codes worth knowing: F5 DC-bus overvoltage (decel too fast / regen), F4 undervoltage, F7 motor overload, F12 hardware overcurrent, F81/F82 comms loss."),
            ]),
        ]
    )

    // MARK: - Functional safety

    static let functionalSafety = ReferenceArticle(
        id: "functional-safety",
        title: "Functional Safety & GuardLogix",
        summary: "Making the control system itself reduce risk to a proven level — its own standards, its own math, a certified controller, and a signature that seals the tested logic.",
        systemImage: "shield.lefthalf.filled",
        readMinutes: 8,
        sections: [
            .init("standards", "The standards & the numbers", [
                .table(headers: ["Standard", "Rating scale"], rows: [
                    ["IEC 61508", "SIL 1–4 (the base standard)"],
                    ["ISO 13849-1", "PL a–e, built from Category B/1/2/3/4, MTTFd, DCavg, CCF (the common machinery standard)"],
                    ["IEC 62061", "SIL CL 1–3 (machinery, control-system-centric)"],
                    ["IEC 61511", "SIL 1–4 (process-industry safety instrumented systems)"],
                ]),
                .text("You do a risk assessment, decide a required PL or SIL per safety function, design to meet it (architecture + component data), and validate. GuardLogix + Guard I/O + certified instructions are rated to SIL 3 / PLe, Category 4 — the ceiling for machinery."),
            ]),
            .init("architecture", "GuardLogix architecture", [
                .bullets([
                    "GuardLogix 5580 (1756-L8xES/EP) runs standard AND safety logic in one slot; the safety core is internally redundant (1oo2). GuardLogix 5570 needs a separate Safety Partner. Compact GuardLogix 5380 = 5069-L3xERMS2.",
                    "The safety task is a special periodic task, highest priority, with a watchdog tuned to guarantee the safety reaction time.",
                    "Safety tags are a separate class — standard logic can read them, only safety logic can write them.",
                    "Safety I/O: 1756-IB16S / OBV8S, 1734 POINT Guard, 5069 safety I/O, ArmorBlock Guard — dual-channel, pulse-tested, with output readback.",
                    "CIP Safety carries safety data over ordinary EtherNet/IP using the \"black channel\" principle — safety CRC, time-stamping, and a Safety Network Number (SNN) so a mis-wired connection is detected."
                ]),
            ]),
            .init("signature", "The safety signature", [
                .text("Once the safety logic is written and validated, you generate a safety signature — an ID + timestamp + CRC over all safety logic, tags, and I/O configuration. With a signature present and the project safety-locked, the safety portion cannot be edited; any change requires deleting the signature (visible, logged) and re-validating. Standard logic can still be edited online with the signature intact."),
                .field("The signature is what a functional-safety assessor and your change-management rely on: \"this exact safety system was tested.\" Record it in the machine file."),
            ]),
            .init("devices", "Safety devices & drive safety", [
                .table(headers: ["Device", "Function"], rows: [
                    ["800F E-stop", "Direct-opening mushroom head, dual NC contacts"],
                    ["440G-LZ / TLS", "Guard locking — hold a guard closed until motion stops"],
                    ["440N SensaGuard", "Non-contact coded RFID interlock, defeat-resistant"],
                    ["450L GuardShield", "Safety light curtain with muting and blanking"],
                    ["Guardmaster MSR / 440C-CR30", "Fixed-function / configurable safety relays — for a single machine with a few E-stops and gates"],
                ]),
                .text("Drive safety functions: STO (Safe Torque Off — remove gate power, motor coasts, dual-channel verified), SS1 (ramp then STO), SS2 / SOS (decelerate to and hold a safe standstill), SLS (Safely Limited Speed — permit motion but trip above a safe limit, for jog/teach). Hardwired on PowerFlex 525; via the 20-750-S3 card on the 755; integrated on Kinetix 5700 ERS4."),
                .caution("An MCR zone, a normal OTE dropping a contactor, or an interlock rung in the standard task is NOT a rated safety function no matter how carefully written. Rated safety comes from certified hardware, certified instructions, dual-channel wiring, and a validated design with a signature. Use standard logic for process interlocks; use the safety system for personnel protection."),
            ]),
        ]
    )
}

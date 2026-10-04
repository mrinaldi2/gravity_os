"""Opens the enums quicktype generates (Architect review F6).

quicktype emits closed `enum X: String, Codable`, so a variant a newer daemon
adds would fail decoding of the whole card or board on an older phone, against
the contract's "additive keeps the version" rule. Each enum becomes an open
one: the known cases, plus `unknown(String)` that keeps any other value so it
round-trips. Reads Swift on stdin, writes it on stdout.
"""
import re
import sys

ENUM = re.compile(r"^enum (\w+): String, Codable \{$")
CASE = re.compile(r'^    case (`?\w+`?) = "((?:[^"\\]|\\.)*)"$')


def opened(name, cases):
    out = [f"enum {name}: Codable, Hashable {{"]
    out += [f"    case {case}" for case, _ in cases]
    out += [
        "    /// A value this app does not know yet; kept so it round-trips.",
        "    case unknown(String)",
        "",
        "    init(rawValue: String) {",
        "        switch rawValue {",
    ]
    out += [f'        case "{raw}": self = .{case}' for case, raw in cases]
    out += [
        "        default: self = .unknown(rawValue)",
        "        }",
        "    }",
        "",
        "    var rawValue: String {",
        "        switch self {",
    ]
    out += [f'        case .{case}: "{raw}"' for case, raw in cases]
    out += [
        "        case .unknown(let value): value",
        "        }",
        "    }",
        "",
        "    init(from decoder: Decoder) throws {",
        "        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))",
        "    }",
        "",
        "    func encode(to encoder: Encoder) throws {",
        "        var container = encoder.singleValueContainer()",
        "        try container.encode(rawValue)",
        "    }",
        "}",
    ]
    return out


def main():
    lines = sys.stdin.read().split("\n")
    out, i, count = [], 0, 0
    while i < len(lines):
        match = ENUM.match(lines[i])
        if not match:
            out.append(lines[i])
            i += 1
            continue
        cases, i = [], i + 1
        while lines[i] != "}":
            case = CASE.match(lines[i])
            if not case:
                sys.exit(f"open_enums.py: unexpected line in enum {match.group(1)}: {lines[i]!r}")
            cases.append((case.group(1), case.group(2)))
            i += 1
        out += opened(match.group(1), cases)
        i += 1
        count += 1
    if count == 0:
        sys.exit("open_enums.py: found no enums; has quicktype's output changed?")
    sys.stdout.write("\n".join(out))


main()

//
//  vern-tokenized-corpus-parity-harness.swift
//  Out-of-band parity probe for the default-off tokenized vernacular corpus.
//
//  Usage:
//    vern-tokenized-corpus-parity-harness /path/to/HourglassExecutable [subject1,subject2,...]
//
//  The harness runs the real app's existing HOURGLASS_PANEL_BENCH profile dump
//  twice per subject, with `vernacular.profile.tokenizedCorpus` OFF then ON,
//  and diffs the normalized `BENCH::   profile.*` rows. Timing rows are ignored;
//  profile stats/lists/diagnostics are compared byte-for-byte.
//

import Foundation

struct RunResult {
    let status: Int32
    let output: String
}

func run(_ executable: String, subject: String, tokenized: Bool) throws -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [
        "-vernacular.profile.enabled", "YES",
        "-vernacular.profile.embeddings.enabled", "NO",
        "-vernacular.profile.reclaimed.llmClassify", "NO",
        "-vernacular.profile.tokenizedCorpus", tokenized ? "YES" : "NO",
        "-vernacular.subject", subject,
    ]
    var env = ProcessInfo.processInfo.environment
    env["HOURGLASS_PANEL_BENCH"] = "1"
    process.environment = env

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return RunResult(status: process.terminationStatus,
                     output: String(data: data, encoding: .utf8) ?? "")
}

func normalizedProfileLines(_ output: String) -> [String] {
    output.split(separator: "\n").compactMap { raw in
        let line = String(raw)
        guard line.contains("BENCH::   profile.") || line.contains("BENCH::     #")
                || line.contains("BENCH::     llm") else { return nil }
        if line.contains("profile.reclaimed.llmClassify") { return nil }
        return line
    }
}

func firstTripwire(_ lines: [String]) -> String {
    lines.first(where: { $0.contains("profile.stats") }) ?? "(missing profile.stats)"
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: \(args[0]) /path/to/HourglassExecutable [subject1,subject2,...]\n", stderr)
    exit(2)
}

let executable = args[1]
let subjects = args.count >= 3
    ? args[2].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    : ["You"]

var failures = 0
for subject in subjects {
    print("TOKENIZED-PARITY:: subject=\"\(subject)\"")
    do {
        let legacy = try run(executable, subject: subject, tokenized: false)
        let cached = try run(executable, subject: subject, tokenized: true)
        guard legacy.status == 0, cached.status == 0 else {
            print("TOKENIZED-PARITY:: FAIL process status legacy=\(legacy.status) cached=\(cached.status)")
            failures += 1
            continue
        }
        let lhs = normalizedProfileLines(legacy.output)
        let rhs = normalizedProfileLines(cached.output)
        print("TOKENIZED-PARITY:: legacy \(firstTripwire(lhs))")
        print("TOKENIZED-PARITY:: cached \(firstTripwire(rhs))")
        if lhs == rhs {
            print("TOKENIZED-PARITY:: PASS subject=\"\(subject)\" lines=\(lhs.count)")
        } else {
            print("TOKENIZED-PARITY:: FAIL subject=\"\(subject)\" legacyLines=\(lhs.count) cachedLines=\(rhs.count)")
            let limit = min(lhs.count, rhs.count)
            var reported = false
            for i in 0..<limit where lhs[i] != rhs[i] {
                print("TOKENIZED-PARITY:: first-diff line \(i + 1)")
                print("  legacy: \(lhs[i])")
                print("  cached: \(rhs[i])")
                reported = true
                break
            }
            if !reported, lhs.count != rhs.count {
                print("TOKENIZED-PARITY:: first-diff line \(limit + 1)")
                print("  legacy: \(lhs.dropFirst(limit).first ?? "<end>")")
                print("  cached: \(rhs.dropFirst(limit).first ?? "<end>")")
            }
            failures += 1
        }
    } catch {
        print("TOKENIZED-PARITY:: FAIL subject=\"\(subject)\" error=\(error)")
        failures += 1
    }
}

if failures == 0 {
    print("TOKENIZED-PARITY:: ALL PASS")
    exit(0)
} else {
    print("TOKENIZED-PARITY:: FAILURES \(failures)")
    exit(1)
}

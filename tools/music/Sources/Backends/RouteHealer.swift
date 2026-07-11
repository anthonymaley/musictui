// tools/music/Sources/Backends/RouteHealer.swift
//
// Evidence-ordered heal ladder (spec §Heal ladder). Dropped with evidence:
// re-issuing `set selected` (no-op against a live broken state), list-writing
// the same device (no-op, zero churn), UI-scripting the popover (macOS 26
// chrome is AX-invisible). Tier 1 is the programmatic equivalent of the
// user's manual popover fix; tier 2 adds a transport cycle (UNVERIFIED in
// the spike — validated by scripts/airplay-live-probe.sh before reliance).
import Foundation

struct RouteHealer {
    struct Outcome {
        let healed: Bool
        /// 1/2 = tier that healed; 3 = honest failure.
        let tierUsed: Int
        /// The tier-3 message when healed == false.
        let failure: String?
    }

    let backend: AppleScriptBackend
    let verifier: RouteVerifier

    /// Heal a target whose establishment verify failed. `groupNames` is the
    /// FULL intended output set (heals must not shrink a multi-speaker group);
    /// `computerName` is the local device (kind == "computer").
    /// Mid-play only — callers guarantee playback is running (routing issued
    /// while paused is untrusted by design; spec §Ordering rule).
    func heal(target: String, ip: String, groupNames: [String], computerName: String,
              scriptingClaims: String) -> Outcome {
        // Tier 1: away-and-back list-write. Routing stays its own osascript
        // call (parameter-error-50 rule).
        if runTier(away: [computerName], back: groupNames, ip: ip, pauseBracket: false) {
            return Outcome(healed: true, tierUsed: 1, failure: nil)
        }
        // Tier 2: same, bracketed by a transport cycle.
        if runTier(away: [computerName], back: groupNames, ip: ip, pauseBracket: true) {
            return Outcome(healed: true, tierUsed: 2, failure: nil)
        }
        return Outcome(healed: false, tierUsed: 3,
                       failure: Self.honestFailureMessage(
                           speaker: target, ip: ip,
                           evidence: "no session traffic after 2 heal attempts",
                           scriptingClaims: scriptingClaims))
    }

    private func runTier(away: [String], back: [String], ip: String, pauseBracket: Bool) -> Bool {
        func listWrite(_ names: [String]) -> Bool {
            let list = names
                .map { "AirPlay device \"\(escapeAppleScriptString($0))\"" }
                .joined(separator: ", ")
            do {
                _ = try syncRun { try await backend.runMusic("set current AirPlay devices to {\(list)}") }
                return true
            } catch {
                verbose("heal: list-write to {\(names.joined(separator: ", "))} failed: \(error.localizedDescription)")
                return false
            }
        }
        guard let baseline = try? verifier.snapshot(ip: ip) else {
            verbose("heal: baseline snapshot for \(ip) failed — skipping tier")
            return false
        }
        if pauseBracket { _ = try? syncRun { try await backend.runMusic("pause") } }
        guard listWrite(away) else { return false }
        // HomePods need a beat to tear down; 1.5s matches resetAirPlaySpeakers.
        Thread.sleep(forTimeInterval: 1.5)
        guard listWrite(back) else { return false }
        if pauseBracket {
            do { _ = try syncRun { try await backend.runMusic("play") } }
            catch { verbose("heal: play after tier-2 reroute failed: \(error.localizedDescription)") }
        }
        do {
            return try verifier.verifyEstablishment(ip: ip, baseline: baseline).verified
        } catch {
            verbose("heal: post-reroute verify errored: \(error.localizedDescription)")
            return false
        }
    }

    static func honestFailureMessage(speaker: String, ip: String,
                                     evidence: String, scriptingClaims: String) -> String {
        """
        ✗ Route to \(speaker) NOT verified: \(evidence).
          Manual fix that works: click the AirPlay icon in Music, deselect and reselect \(speaker).
          (network: \(evidence) [\(ip)] · scripting claims: \(scriptingClaims))
        """
    }
}

/// Shared post-play verification pass (CLI play path, speaker commands, TUI).
/// `baselines`/`ips` are captured BEFORE routing. Returns printable lines.
func verifyAndHealRoutes(speakers: [String], backend: AppleScriptBackend,
                         baselines: [String: Set<TCPConnection>],
                         ips: [String: String],
                         verifier: RouteVerifier = RouteVerifier()) -> [String] {
    var lines: [String] = []
    let devices = (try? fetchSpeakerDevices()) ?? []
    let computerName = devices.first { ($0["kind"] as? String) == "computer" }?["name"] as? String
    let healer = RouteHealer(backend: backend, verifier: verifier)

    for speaker in speakers {
        guard let ip = ips[speaker], let baseline = baselines[speaker] else {
            lines.append("· \(speaker): could not resolve IP via Bonjour — routed but unverified.")
            continue
        }
        // Fast path: the route may already be established (e.g. resuming on
        // the already-routed speaker — pause does not tear down an AirPlay
        // session, so the delta poll would see no churn and time out into an
        // unnecessary heal). The steady-state fingerprint costs one netstat
        // read and cannot pass for a just-torn-down route (teardown removes
        // the session's second :7000 connection — spike evidence).
        if let steady = try? verifier.steadyState(ip: ip), steady.verified {
            lines.append("✓ \(speaker) verified (\(steady.evidence))")
            continue
        }
        let verdict = (try? verifier.verifyEstablishment(ip: ip, baseline: baseline))
            ?? RouteVerdict(verified: false, evidence: "verification errored", advisory: nil)
        if verdict.verified {
            lines.append("✓ \(speaker) verified (\(verdict.evidence))")
            continue
        }
        // No computer device identified (Music scripting degraded) — healing
        // needs a real away-target; say so instead of attempting a heal
        // against a bogus device name.
        guard let computerName else {
            lines.append("✗ \(speaker) NOT verified (\(verdict.evidence)) — cannot heal: couldn't identify the computer device. Manual fix: click the AirPlay icon in Music, deselect and reselect \(speaker).")
            continue
        }
        // Advisory context for the failure path: what the (lying) scripting
        // layer claims right now.
        let claims = (try? syncRun {
            try await backend.runMusic("""
                get "selected=" & (selected of AirPlay device "\(escapeAppleScriptString(speaker))" as text) & \
                " active=" & (active of AirPlay device "\(escapeAppleScriptString(speaker))" as text)
            """)
        })?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unreadable"
        let outcome = withStatus("Healing \(speaker) route...") {
            healer.heal(target: speaker, ip: ip, groupNames: speakers,
                        computerName: computerName, scriptingClaims: claims)
        }
        if outcome.healed {
            lines.append("✓ \(speaker) verified after heal (tier \(outcome.tierUsed))")
        } else {
            lines.append(outcome.failure ?? "✗ \(speaker) NOT verified")
        }
    }
    return lines
}

//
//  VernacularEngine.swift
//  Hourglass - Unified Vernacular Profile
//

import Foundation

/// New Phase-1 profile engine. Pure and synchronous; callers decide whether to
/// enable it by passing `VernacularConfig`.
enum VernacularEngine {
    static func buildProfile(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        contacts: ResolvedContacts,
        subject: VernacularSubject = .you,
        config baseConfig: VernacularConfig = .default,
        tokenized: VernacularTokenizedCorpus? = nil
    ) -> VernacularProfile {
        guard baseConfig.isEnabled else { return .disabled }
        let subjectContext = VernacularSubjectContext.build(messages: messages, subject: subject)
        // Count gates scale to the SUBJECT's volume (a contact's visible slice
        // is 10-100× smaller than the owner's full history), and non-owner
        // subjects get contact-mode classifier thresholds. The reference is
        // the MEASURED owner volume from this corpus — counted, not assumed —
        // so the owner's own gates are the tuned defaults by construction.
        let ownerVolume = subject.isYou
            ? subjectContext.subjectMessageCount
            : messages.count(where: { $0.fromMe })
        let config = baseConfig.scaledForSubject(
            subjectMessageCount: subjectContext.subjectMessageCount,
            referenceVolume: ownerVolume,
            isYou: subject.isYou
        )
        guard subjectContext.subjectMessageCount >= config.minSubjectMessagesForProfile else {
            return VernacularProfile(
                isEnabled: true,
                subject: subject,
                words: [],
                circleSlang: [],
                phrases: [],
                reclaimedWords: [],
                templates: [],
                topics: [],
                stats: VernacularProfile.Stats(
                    subjectName: subject.displayName,
                    subjectIsYou: subject.isYou,
                    lowConfidence: true,
                    caveat: subjectContext.visibleCorpusCaveat,
                    totalMessages: messages.count,
                    worldMessages: subjectContext.worldMessageCount,
                    sentMessages: subjectContext.subjectMessageCount,
                    receivedMessages: subjectContext.otherMessageCount,
                    corpusMaxDate: messages.map(\.date).max()
                )
            )
        }

        let benchEnabled = ProcessInfo.processInfo.environment["HOURGLASS_PANEL_BENCH"] != nil
        func bench(_ label: String, since start: Date?) {
            guard let start else { return }
            print("BENCH::     \(label) \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            fflush(stdout)
        }

        let ngramStart = benchEnabled ? Date() : nil
        let ngrams = VernacularNgramExtractor.extract(messages: messages, baseline: baseline,
                                                      contacts: contacts,
                                                      subjectContext: subjectContext,
                                                      config: config,
                                                      tokenized: tokenized)
        bench("profile.ngrams", since: ngramStart)

        let templateStart = benchEnabled ? Date() : nil
        let templates = VernacularTemplateEngine.mine(messages: messages, baseline: baseline,
                                                      contacts: contacts,
                                                      activeContacts: ngrams.activeContacts,
                                                      subjectContext: subjectContext,
                                                      config: config,
                                                      tokenized: tokenized)
        bench("profile.templates", since: templateStart)

        let semanticStart = benchEnabled ? Date() : nil
        let enrichedCandidates = VernacularSemanticEnricher.enrich(candidates: ngrams.candidates,
                                                                   messages: messages,
                                                                   subjectContext: subjectContext,
                                                                   config: config)
        bench("profile.semantic", since: semanticStart)

        let scoreStart = benchEnabled ? Date() : nil
        let words = VernacularScorer.scoreWords(enrichedCandidates, subject: subject, config: config)
        let circleSlang = VernacularScorer.scoreCircleSlang(enrichedCandidates, subject: subject, config: config)
        let topics = VernacularScorer.scoreTopics(enrichedCandidates, subject: subject, config: config)
        let templateItems = VernacularScorer.scoreTemplates(templates.candidates, subject: subject, config: config)
        let reclaimedLimit = config.enableReclaimedContextFilter
            ? max(config.reclaimedWordCount, config.reclaimedContextCandidateLimit)
            : config.reclaimedWordCount
        let reclaimedRanked = VernacularScorer.scoreReclaimedWords(enrichedCandidates,
                                                                   subject: subject,
                                                                   config: config,
                                                                   limit: reclaimedLimit)
        let reclaimedContext = ReclaimedContextClassifier.classify(
            reclaimedRanked,
            messages: messages,
            subjectContext: subjectContext,
            trustedSlangSurfaces: trustedSlangSurfaces(words: words,
                                                       circleSlang: circleSlang,
                                                       templates: templateItems),
            config: config
        )
        let reclaimedWords = reclaimedContext.filtered

        // Phrases score AFTER the slang lists exist so slang-bearing phrases
        // ("are we deadass") can outrank logistics scaffolding ("lmk when ur").
        var slangSurfaces = Set<String>()
        for item in words where item.n == 1 { slangSurfaces.insert(item.surface) }
        for item in circleSlang where item.n == 1 { slangSurfaces.insert(item.surface) }
        for item in reclaimedWords {
            for token in item.surface.split(separator: " ") { slangSurfaces.insert(String(token)) }
        }
        let phrases = VernacularScorer.scorePhrases(enrichedCandidates, subject: subject,
                                                    config: config, slangSurfaces: slangSurfaces)

        // Signature frames — emphatic-caps ("___ is NOT ___", "I MAY ___") and
        // vocative ("brother ___") constructions — ranked above the auto-mined
        // templates. Subject=You only: it's the device owner's voice, and the
        // vocative pass shouldn't run on every lazy per-contact click.
        var templatesFinal = templateItems
        if config.signatureFramesEnabled && subject.isYou {
            let signature = VernacularSignatureFrames.mine(messages: messages,
                                                           subjectContext: subjectContext,
                                                           baseline: baseline,
                                                           config: config)
            templatesFinal = VernacularSignatureFrames.mergeAtTop(signature, into: templateItems)
        }
        bench("profile.score", since: scoreStart)

        let stats = VernacularProfile.Stats(
            subjectName: subject.displayName,
            subjectIsYou: subject.isYou,
            lowConfidence: false,
            caveat: subjectContext.visibleCorpusCaveat,
            totalMessages: messages.count,
            worldMessages: subjectContext.worldMessageCount,
            sentMessages: subjectContext.subjectMessageCount,
            receivedMessages: subjectContext.otherMessageCount,
            activeContacts: ngrams.activeContacts,
            candidateNgramHashes: ngrams.candidateHashCount,
            exactNgramCandidates: ngrams.exactCandidateCount,
            candidateTemplateHashes: templates.candidateHashCount,
            exactTemplateCandidates: templates.exactCandidateCount,
            corpusMaxDate: messages.map(\.date).max()
        )
        return VernacularProfile(isEnabled: true, subject: subject,
                                 words: words, circleSlang: circleSlang,
                                 phrases: phrases, reclaimedWords: reclaimedWords,
                                 reclaimedContextDiagnostics: reclaimedContext.diagnostics,
                                 templates: templatesFinal,
                                 topics: topics, stats: stats)
    }

    private static func trustedSlangSurfaces(
        words: [VernacularProfilePhrase],
        circleSlang: [VernacularProfilePhrase],
        templates: [VernacularProfileTemplate]
    ) -> Set<String> {
        var surfaces = Set<String>()
        for item in words where item.n == 1 {
            surfaces.insert(item.surface)
        }
        for item in circleSlang where item.n == 1 {
            surfaces.insert(item.surface)
        }
        for template in templates {
            for anchor in template.anchors where anchor.count >= 2 {
                surfaces.insert(anchor)
            }
        }
        return surfaces
    }
}

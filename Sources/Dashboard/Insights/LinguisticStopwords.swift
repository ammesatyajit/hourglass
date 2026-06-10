//
//  LinguisticStopwords.swift
//  Hourglass — Linguistic Insights
//
//  A compact English function-word stopword list used as a BACKSTOP in the
//  distinctive-vocabulary analysis. The primary filter is the surprisal /
//  log-odds comparison against the bundled baseline corpus — that already
//  buries "the", "and", "you" because they are common in the baseline too.
//
//  This explicit list catches a different failure mode: function words and
//  texting filler that a heavy texter uses SO much more than the baseline
//  that they'd still float to the top of a pure log-odds ranking despite
//  being uninteresting ("i", "u", "im", "dont", "ur", "ok"). We don't want
//  the headline "distinctive word" to be "u" — that's not an insight, it's
//  noise. So these are removed before ranking distinctive vocabulary.
//
//  Pure data + a membership check. No I/O.
//

import Foundation

public enum LinguisticStopwords {

    /// Lowercased function words + ubiquitous texting filler. Kept
    /// deliberately tight: we only exclude words that are genuinely
    /// content-free. Slang with semantic color ("lowkey", "deadass",
    /// "fr", "ngl", "bet") is INTENTIONALLY absent — those are exactly
    /// what the panel wants to surface.
    public static let words: Set<String> = [
        // Articles / determiners
        "a", "an", "the", "this", "that", "these", "those", "such",
        // Pronouns (+ common texting contractions of them)
        "i", "me", "my", "mine", "myself", "we", "us", "our", "ours",
        "you", "u", "your", "ur", "yours", "yourself", "yall", "y'all",
        "he", "him", "his", "she", "her", "hers", "it", "its", "they",
        "them", "their", "theirs", "who", "whom", "whose", "which", "what",
        "ya", "em",
        // Common contraction stems / fragments (apostrophe-less)
        "im", "ima", "imma", "dont", "doesnt", "didnt", "cant", "wont",
        "isnt", "arent", "wasnt", "werent", "hasnt", "havent", "hadnt",
        "wouldnt", "couldnt", "shouldnt", "aint", "ive", "youre", "theyre",
        "thats", "whats", "hes", "shes", "lets", "id", "ill",
        "s", "t", "m", "re", "ve", "ll", "d",
        // Apostrophe contraction forms (our tokenizer keeps interior
        // apostrophes, so "i'm"/"it's"/"don't" arrive whole — bury them).
        "i'm", "it's", "that's", "what's", "he's", "she's", "there's",
        "here's", "let's", "who's", "i'll", "i've", "i'd", "you're",
        "you've", "you'll", "you'd", "we're", "we've", "we'll", "they're",
        "they've", "they'll", "don't", "doesn't", "didn't", "can't",
        "won't", "isn't", "aren't", "wasn't", "weren't", "hasn't",
        "haven't", "hadn't", "wouldn't", "couldn't", "shouldn't", "ain't",
        // To-be / auxiliaries / modals
        "am", "is", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "doing", "done",
        "have", "has", "had", "having",
        "will", "would", "shall", "should", "can", "could", "may", "might",
        "must", "ought",
        // Conjunctions / prepositions
        "and", "or", "but", "nor", "so", "yet", "if", "then", "than",
        "because", "as", "until", "while", "of", "at", "by", "for", "with",
        "about", "against", "between", "into", "through", "during", "before",
        "after", "above", "below", "to", "from", "up", "down", "in", "out",
        "on", "off", "over", "under", "again", "further", "once", "onto",
        // Adverbs / quantifiers that are mostly glue
        "here", "there", "when", "where", "why", "how", "all", "any",
        "both", "each", "few", "more", "most", "other", "some", "no", "not",
        "only", "own", "same", "too", "very", "just", "now", "also",
        "even", "still", "much", "many",
        // High-frequency texting filler that is content-free
        "yeah", "yea", "yep", "yup", "ok", "okay", "oh", "ah", "um",
        "uh", "hmm", "well", "like", "got", "get", "go", "going", "gonna",
        "wanna", "gotta", "lemme", "kinda", "sorta", "really",
    ]

    /// Is this token a function word / filler we should drop from the
    /// distinctive-vocabulary ranking?
    public static func isStopword(_ token: String) -> Bool {
        words.contains(token)
    }
}

package com.plushpal.app

import java.util.Locale

internal object ParentProfileValidator {
    private val approvedTraits = setOf(
        "cheerful", "curious", "gentle", "patient", "playful", "calm", "encouraging",
    )
    private val blockedGuidance = listOf(
        "ignore safety", "keep secrets", "ask for their address",
    )

    fun isValid(
        ageBand: String?,
        characterAlias: String,
        characterTraits: List<String>,
        parentGuidance: String,
        retentionDays: Int,
    ): Boolean = validationError(
        ageBand,
        characterAlias,
        characterTraits,
        parentGuidance,
        retentionDays,
    ) == null

    fun validationError(
        ageBand: String?,
        characterAlias: String,
        characterTraits: List<String>,
        parentGuidance: String,
        retentionDays: Int,
    ): String? {
        val alias = characterAlias.trim()
        val normalizedGuidance = parentGuidance.lowercase(Locale.ROOT)
        if (ageBand !in setOf("4-5", "6-8", "9-12")) {
            return "Choose a child age band."
        }
        if (alias.length !in 2..40) {
            return "Character name must be 2-40 characters."
        }
        if (!alias.all { it.isLetterOrDigit() || it.isWhitespace() || it in setOf('-', '\'', '.', '&') }) {
            return "Character name can use letters, numbers, spaces, hyphens, apostrophes, periods, or ampersands."
        }
        if (characterTraits.size > 5 || !characterTraits.all(approvedTraits::contains)) {
            return "Choose up to 5 approved personality traits."
        }
        if (parentGuidance.length > 2_000) {
            return "Parent guidance must be 2,000 characters or less."
        }
        if (blockedGuidance.any(normalizedGuidance::contains)) {
            return "Parent guidance contains unsafe instructions."
        }
        if (retentionDays !in setOf(0, 1, 7, 30)) {
            return "Choose a supported conversation-history retention setting."
        }
        return null
    }
}

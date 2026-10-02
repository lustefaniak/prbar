import CEL
import CELSwift
import Foundation

/// The repository a `configure` rule decides settings for.
struct RepoFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Repo"
    var owner: String
    var name: String
    /// `owner/name`.
    var fullName: String

    init(owner: String, name: String) {
        self.owner = owner
        self.name = name
        self.fullName = "\(owner)/\(name)"
    }
}

/// The `configure` stage: how a repository's pull requests are reviewed.
/// It sees the repository only, so its answer holds for every PR there
/// and can be resolved wherever a repository's settings are needed.
struct ConfigureFacts: Codable, Sendable, Hashable {
    var repo: RepoFacts
    var lists: [String: [String]]
}

/// The `configure` stage's output: the settings a `repos:` entry in
/// prbar.yaml used to hold, every one optional. Each file's first match
/// applies, files in name order, a later file's fields replacing an
/// earlier one's; what no rule sets comes from the review defaults.
/// The three gate blocks replace as a whole, as they always have.
struct RuleConfiguration: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Configuration"

    struct AutoApprove: Codable, Sendable, Hashable, CELNamedType {
        static let celTypeName = "prbar.AutoApprove"
        var enabled: Bool?
        var minConfidence: Double?
        var claudeMinConfidence: Double?
        var codexMinConfidence: Double?
        var allowApproveWithNotes: Bool?
        var maxAnnotationSeverity: AnnotationSeverity?
        var maxAnnotations: Int?
        var maxAdditions: Int?
        var maxDeletions: Int?
        var maxChangedFiles: Int?
        var postAttributionComment: Bool?
        var postInlineAnnotations: Bool?
    }

    struct AutoDeny: Codable, Sendable, Hashable, CELNamedType {
        static let celTypeName = "prbar.AutoDeny"
        var action: AutoDenyAction?
        var minConfidence: Double?
        var claudeMinConfidence: Double?
        var codexMinConfidence: Double?
        var requiredSeverity: AnnotationSeverity?
        var minMatchingAnnotations: Int?
        var maxAdditions: Int?
        var postInlineAnnotations: Bool?
    }

    struct ResolveThreads: Codable, Sendable, Hashable, CELNamedType {
        static let celTypeName = "prbar.ResolveThreads"
        var enabled: Bool?
        var minConfidence: Double?
    }

    var rule: String
    var splitMode: SplitMode?
    var rootPatterns: [String]?
    var unmatchedStrategy: UnmatchedStrategy?
    var minFilesPerSubreview: Int?
    var maxParallelSubreviews: Int?
    var collapseAboveSubreviewCount: Int?
    var toolMode: ToolMode?
    var customSystemPrompt: String?
    var replaceBaseSystemPrompt: Bool?
    var maxToolCallsPerSubreview: Int?
    var maxCostUsdPerSubreview: Double?
    var reviewTimeoutSeconds: Int?
    var riskBriefEnabled: Bool?
    var churnWindowDays: Int?
    var churnHistoryDepth: Int?
    var autoApprove: AutoApprove?
    var autoDeny: AutoDeny?
    var shareFindings: ShareFindingsPolicy?
    var shareMinConfidence: Double?
    var shareMaxComments: Int?
    var resolveThreads: ResolveThreads?
    var reviewDrafts: Bool?
    var excludeTitlePatterns: [String]?
    var agentEnvironment: [String: String]?
    var skipAiIfReviewedByOthers: Bool?
    var aiReviewEnabled: Bool?
    var provider: ProviderID?
    var claudeModel: String?
    var claudeEffort: String?
    var codexModel: String?
    var codexEffort: String?
    var notifyPolicy: NotifyPolicy?
    var skipMergeConfirmation: Bool?
    var forceFullReview: Bool?

    init(rule: String) {
        self.rule = rule
    }
}

extension RuleConfiguration {
    /// Sets on `config` every field this output sets.
    func apply(to config: inout RepoConfig) {
        if let splitMode { config.splitMode = splitMode }
        if let rootPatterns { config.rootPatterns = rootPatterns }
        if let unmatchedStrategy { config.unmatchedStrategy = unmatchedStrategy }
        if let minFilesPerSubreview { config.minFilesPerSubreview = minFilesPerSubreview }
        if let maxParallelSubreviews { config.maxParallelSubreviews = maxParallelSubreviews }
        if let collapseAboveSubreviewCount { config.collapseAboveSubreviewCount = collapseAboveSubreviewCount }
        if let toolMode { config.toolModeOverride = toolMode }
        if let customSystemPrompt { config.customSystemPrompt = customSystemPrompt }
        if let replaceBaseSystemPrompt { config.replaceBaseSystemPrompt = replaceBaseSystemPrompt }
        if let maxToolCallsPerSubreview { config.maxToolCallsPerSubreview = maxToolCallsPerSubreview }
        if let maxCostUsdPerSubreview { config.maxCostUsdPerSubreview = maxCostUsdPerSubreview }
        if let reviewTimeoutSeconds { config.reviewTimeoutSeconds = reviewTimeoutSeconds }
        if let riskBriefEnabled { config.riskBriefEnabled = riskBriefEnabled }
        if let churnWindowDays { config.churnWindowDays = churnWindowDays }
        if let churnHistoryDepth { config.churnHistoryDepth = churnHistoryDepth }
        if let autoApprove { config.autoApprove = autoApprove.config }
        if let autoDeny { config.autoDeny = autoDeny.config }
        if let shareFindings { config.shareFindings = shareFindings }
        if let shareMinConfidence { config.shareMinConfidence = shareMinConfidence }
        if let shareMaxComments { config.shareMaxComments = shareMaxComments }
        if let resolveThreads { config.resolveThreads = resolveThreads.config }
        if let reviewDrafts { config.reviewDrafts = reviewDrafts }
        if let excludeTitlePatterns { config.excludeTitlePatterns = excludeTitlePatterns }
        if let agentEnvironment { config.agentEnvironment = agentEnvironment }
        if let skipAiIfReviewedByOthers { config.skipAIIfReviewedByOthers = skipAiIfReviewedByOthers }
        if let aiReviewEnabled { config.aiReviewEnabled = aiReviewEnabled }
        if let provider { config.providerOverride = provider }
        if let claudeModel { config.claudeModelOverride = claudeModel }
        if let claudeEffort { config.claudeEffortOverride = claudeEffort }
        if let codexModel { config.codexModelOverride = codexModel }
        if let codexEffort { config.codexEffortOverride = codexEffort }
        if let notifyPolicy { config.notifyPolicy = notifyPolicy }
        if let skipMergeConfirmation { config.skipMergeConfirmation = skipMergeConfirmation }
        if let forceFullReview { config.forceFullReview = forceFullReview }
    }

    /// The output that sets what a prbar.yaml `repos:` entry set, for the
    /// converter. What moved to `repositories:` (excluded, trustRepoRules)
    /// is left out.
    init(_ repo: RepoConfig, rule: String) {
        self.init(rule: rule)
        splitMode = repo.splitMode
        rootPatterns = repo.rootPatterns.isEmpty ? nil : repo.rootPatterns
        unmatchedStrategy = repo.unmatchedStrategy
        minFilesPerSubreview = repo.minFilesPerSubreview
        maxParallelSubreviews = repo.maxParallelSubreviews
        collapseAboveSubreviewCount = repo.collapseAboveSubreviewCount
        toolMode = repo.toolModeOverride
        customSystemPrompt = repo.customSystemPrompt
        replaceBaseSystemPrompt = repo.replaceBaseSystemPrompt
        maxToolCallsPerSubreview = repo.maxToolCallsPerSubreview
        maxCostUsdPerSubreview = repo.maxCostUsdPerSubreview
        reviewTimeoutSeconds = repo.reviewTimeoutSeconds
        riskBriefEnabled = repo.riskBriefEnabled
        churnWindowDays = repo.churnWindowDays
        churnHistoryDepth = repo.churnHistoryDepth
        autoApprove = repo.autoApprove.map(AutoApprove.init)
        autoDeny = repo.autoDeny.map(AutoDeny.init)
        shareFindings = repo.shareFindings
        shareMinConfidence = repo.shareMinConfidence
        shareMaxComments = repo.shareMaxComments
        resolveThreads = repo.resolveThreads.map(ResolveThreads.init)
        reviewDrafts = repo.reviewDrafts
        excludeTitlePatterns = repo.excludeTitlePatterns
        agentEnvironment = repo.agentEnvironment
        skipAiIfReviewedByOthers = repo.skipAIIfReviewedByOthers
        aiReviewEnabled = repo.aiReviewEnabled
        provider = repo.providerOverride
        claudeModel = repo.claudeModelOverride
        claudeEffort = repo.claudeEffortOverride
        codexModel = repo.codexModelOverride
        codexEffort = repo.codexEffortOverride
        notifyPolicy = repo.notifyPolicy
        skipMergeConfirmation = repo.skipMergeConfirmation
        forceFullReview = repo.forceFullReview
    }
}

extension RuleConfiguration.AutoApprove {
    /// Unset fields keep the shipped defaults, as a sparse prbar.yaml
    /// block did.
    var config: AutoApproveConfig {
        var c = AutoApproveConfig()
        if let enabled { c.enabled = enabled }
        if let minConfidence { c.minConfidence = minConfidence }
        if let claudeMinConfidence { c.claudeMinConfidence = claudeMinConfidence }
        if let codexMinConfidence { c.codexMinConfidence = codexMinConfidence }
        if let allowApproveWithNotes { c.allowApproveWithNotes = allowApproveWithNotes }
        if let maxAnnotationSeverity { c.maxAnnotationSeverity = maxAnnotationSeverity }
        if let maxAnnotations { c.maxAnnotations = maxAnnotations }
        if let maxAdditions { c.maxAdditions = maxAdditions }
        if let maxDeletions { c.maxDeletions = maxDeletions }
        if let maxChangedFiles { c.maxChangedFiles = maxChangedFiles }
        if let postAttributionComment { c.postAttributionComment = postAttributionComment }
        if let postInlineAnnotations { c.postInlineAnnotations = postInlineAnnotations }
        return c
    }

    /// Only the fields that differ from the shipped defaults.
    init(_ c: AutoApproveConfig) {
        let d = AutoApproveConfig()
        func differing<T: Equatable>(_ value: T, _ shipped: T) -> T? { value == shipped ? nil : value }
        // Always written, so a converted block says what it does.
        enabled = c.enabled
        minConfidence = differing(c.minConfidence, d.minConfidence)
        claudeMinConfidence = c.claudeMinConfidence
        codexMinConfidence = c.codexMinConfidence
        allowApproveWithNotes = differing(c.allowApproveWithNotes, d.allowApproveWithNotes)
        maxAnnotationSeverity = differing(c.maxAnnotationSeverity, d.maxAnnotationSeverity)
        maxAnnotations = differing(c.maxAnnotations, d.maxAnnotations)
        maxAdditions = differing(c.maxAdditions, d.maxAdditions)
        maxDeletions = differing(c.maxDeletions, d.maxDeletions)
        maxChangedFiles = differing(c.maxChangedFiles, d.maxChangedFiles)
        postAttributionComment = differing(c.postAttributionComment, d.postAttributionComment)
        postInlineAnnotations = differing(c.postInlineAnnotations, d.postInlineAnnotations)
    }
}

extension RuleConfiguration.AutoDeny {
    var config: AutoDenyConfig {
        var c = AutoDenyConfig()
        if let action { c.action = action }
        if let minConfidence { c.minConfidence = minConfidence }
        if let claudeMinConfidence { c.claudeMinConfidence = claudeMinConfidence }
        if let codexMinConfidence { c.codexMinConfidence = codexMinConfidence }
        if let requiredSeverity { c.requiredSeverity = requiredSeverity }
        if let minMatchingAnnotations { c.minMatchingAnnotations = minMatchingAnnotations }
        if let maxAdditions { c.maxAdditions = maxAdditions }
        if let postInlineAnnotations { c.postInlineAnnotations = postInlineAnnotations }
        return c
    }

    init(_ c: AutoDenyConfig) {
        let d = AutoDenyConfig()
        func differing<T: Equatable>(_ value: T, _ shipped: T) -> T? { value == shipped ? nil : value }
        action = c.action
        minConfidence = differing(c.minConfidence, d.minConfidence)
        claudeMinConfidence = c.claudeMinConfidence
        codexMinConfidence = c.codexMinConfidence
        requiredSeverity = differing(c.requiredSeverity, d.requiredSeverity)
        minMatchingAnnotations = differing(c.minMatchingAnnotations, d.minMatchingAnnotations)
        maxAdditions = differing(c.maxAdditions, d.maxAdditions)
        postInlineAnnotations = differing(c.postInlineAnnotations, d.postInlineAnnotations)
    }
}

extension RuleConfiguration.ResolveThreads {
    var config: ResolveThreadsConfig {
        var c = ResolveThreadsConfig()
        if let enabled { c.enabled = enabled }
        if let minConfidence { c.minConfidence = minConfidence }
        return c
    }

    init(_ c: ResolveThreadsConfig) {
        let d = ResolveThreadsConfig()
        enabled = c.enabled
        minConfidence = c.minConfidence == d.minConfidence ? nil : c.minConfidence
    }
}

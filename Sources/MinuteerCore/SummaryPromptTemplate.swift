import Foundation

public enum SessionType: String, CaseIterable, Sendable, Codable {
    case meeting = "meeting"
    case therapy = "therapy"
    case custom = "custom"

    public var title: String {
        switch self {
        case .meeting: return "Meeting"
        case .therapy: return "Therapy Session"
        case .custom: return "Custom"
        }
    }
}

public struct SummaryPromptTemplate: Sendable, Hashable, Codable {
    public var sessionType: SessionType
    public var systemInstructions: String

    public init(sessionType: SessionType, systemInstructions: String) {
        self.sessionType = sessionType
        self.systemInstructions = systemInstructions
    }

    public static let defaultMeeting = SummaryPromptTemplate(
        sessionType: .meeting,
        systemInstructions: """
        You are an expert executive assistant. Analyze this meeting transcript and produce a clean Markdown summary structured with:
        ## Executive Summary
        A concise overview of the purpose and primary outcomes of the meeting.
        ## Key Decisions
        Numbered list of decisions agreed upon during the discussion.
        ## Action Items & Next Steps
        Checkbox list (- [ ]) of actionable items with assignees and deadlines where mentioned.
        ## Notable Discussion Topics
        Bullet points detailing significant points of debate, context, or updates.
        """
    )

    public static let defaultTherapy = SummaryPromptTemplate(
        sessionType: .therapy,
        systemInstructions: """
        You are a compassionate, thoughtful personal reflection assistant. Analyze this therapy session recording transcript and create a supportive, private Markdown journal note structured with:
        ## Core Themes & Emotional State
        Primary feelings, stressors, or topics explored during the session.
        ## Breakthrough Moments & Key Insights
        Meaningful realizations, reframing, or perspective shifts that occurred.
        ## Patterns & Triggers Discussed
        Identified behavioral or emotional loops and root causes.
        ## Personal Growth & Grounding Takeaways
        Affirmations, reflective questions, and self-care practices to carry forward into the week.
        """
    )

    public func renderPrompt(transcript: String) -> String {
        return """
        \(systemInstructions)

        ---
        ### Transcript to Summarize:
        \(transcript)
        """
    }
}

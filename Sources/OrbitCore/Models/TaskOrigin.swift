import Foundation

/// Where a to-do came from, for the colour coding on Home, Tasks and Calendar:
///   - yours: the student added it (quick add, share sheet, messages, email they accepted)
///   - recommended: Orbit suggested it (assistant, flashcard reviews, reading chunks, careers "Apply" to-dos)
///   - required: uni-assigned work (ELE homework, assessments and their planned steps, Ed deadlines, uni email)
public enum TaskOrigin: String, Codable, CaseIterable, Sendable, Identifiable {
    case yours, recommended, required

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .yours: "You set"
        case .recommended: "Orbit recommends"
        case .required: "Required"
        }
    }

    public var shortLabel: String {
        switch self {
        case .yours: "Yours"
        case .recommended: "Suggested"
        case .required: "Required"
        }
    }

    public static func of(source: TaskSource, sourceRef: String?, moduleCode: String?, assessmentID: String? = nil) -> TaskOrigin {
        let ref = (sourceRef ?? "").lowercased()
        // Orbit's own suggestions, whatever source they were filed under.
        if ref.hasPrefix("reading:") || ref.hasPrefix("careers:") || ref.hasPrefix("orbit-") || ref.hasPrefix("flashcard") {
            return .recommended
        }
        switch source {
        case .manual, .message:
            return .yours
        case .assistant, .notes:
            return .recommended
        case .ele:
            return .required
        case .email:
            // Uni email (a module, an assessment, or an exeter.ac.uk thread) is assigned work.
            if moduleCode != nil || assessmentID != nil || ref.contains("exeter") { return .required }
            return .yours
        }
    }
}

extension OrbitTask {
    public var origin: TaskOrigin {
        TaskOrigin.of(source: source, sourceRef: sourceRef, moduleCode: moduleCode, assessmentID: assessmentID)
    }
}

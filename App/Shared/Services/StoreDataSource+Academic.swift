import Foundation
import OrbitCore

/// The chat assistant's view of the courses. On the Mac the brain hands in the
/// knowledge base and reviews; elsewhere they're empty and the tools say so.
extension StoreDataSource: AcademicDataSource {
    func courseKnowledge() async -> CourseKnowledgeBase {
        knowledgeProvider?() ?? CourseKnowledgeBase(calendar: context.prefs.academicCalendar ?? .exeter2026)
    }

    func lectureReviews() async -> [LectureReview] {
        lectureReviewsProvider?() ?? []
    }

    func noteEmbedder() async -> NoteEmbedder? {
        embedderProvider?()
    }

    func runLectureReview(module: String, week: Int) async -> LectureReview? {
        await lectureReviewRunner?(module, week)
    }
}

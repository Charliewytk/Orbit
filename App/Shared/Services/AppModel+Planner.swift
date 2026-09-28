import Foundation
import SwiftData
import OrbitCore

/// The conversational planner behind Quick Add: "no work today, type up last
/// week by Monday, I missed my 8:35 on Friday" → a reviewed plan.
extension AppModel {
    var conversationalPlanner: ConversationalPlanner {
        ConversationalPlanner(router: backend.planRouter, purpose: .privateData)
    }

    func plannerContext(now: Date = Date()) -> PlannerContext {
        let lectures = backend.plannerLectures()
        let modules = Dictionary(context.all(StoredModule.self).filter { !$0.id.isEmpty }.map { ($0.id, $0.name) },
                                 uniquingKeysWith: { a, _ in a })
        let blocks = context.all(StoredBlock.self)
            .filter { !$0.locked && !$0.completed && !$0.skipped && $0.start > now }
            .map { PlannerContext.FlexibleBlock(id: $0.id, title: $0.title, start: $0.start, end: $0.end) }
        return PlannerContext(now: now, prefs: prefs, events: context.all(StoredEvent.self).map(\.value),
                              lectures: lectures.lectures, moduleNames: modules,
                              tasks: context.all(StoredTask.self).map(\.value), flexibleBlocks: blocks,
                              lectureLinks: lectures.links)
    }

    func proposePlan(_ text: String) async -> PlanProposal {
        await conversationalPlanner.propose(text, context: plannerContext())
    }

    func revisePlan(_ proposal: PlanProposal, reply: String) async -> PlanProposal {
        await conversationalPlanner.revise(proposal, reply: reply, context: plannerContext()).0
    }

    /// Re-slots after a manual edit (time changed, item re-included).
    func reschedule(_ proposal: PlanProposal) -> PlanProposal {
        var p = proposal
        let ctx = plannerContext()
        conversationalPlanner.schedule(&p, context: ctx)
        p.summary = conversationalPlanner.summary(p, context: ctx)
        return p
    }

    /// Creates the tasks (held in their proposed slots) and clears the rest days. Returns tasks added.
    @discardableResult
    func commit(_ proposal: PlanProposal) async -> Int {
        let now = Date()
        var added: [StoredTask] = []
        for item in proposal.items where item.included {
            let stored = StoredTask(task: item.task(createdAt: now))
            context.insert(stored)
            added.append(stored)
            if let start = item.start, let end = item.end {
                let block = StoredBlock()
                block.taskID = stored.id
                block.title = item.title
                block.start = start
                block.end = end
                block.moduleCode = item.moduleCode
                block.locked = true
                context.insert(block)
            }
        }
        context.saveQuietly()
        for day in proposal.restDays { await backend.lighten(day: day, fraction: 1) }
        backend.tasksChanged()
        refreshWidgets()
        let rest = proposal.restDays.isEmpty ? "" : ", kept \(proposal.restDays.count == 1 ? "the day" : "\(proposal.restDays.count) days") free"
        show("Planned \(added.count) thing\(added.count == 1 ? "" : "s")\(rest)", undo: { [weak self] in
            guard let self else { return }
            for t in added { self.delete(t) }
        })
        return added.count
    }
}

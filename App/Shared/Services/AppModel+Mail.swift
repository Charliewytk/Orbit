import Foundation
import OrbitCore

/// Archive and Delete (move to Trash) from Orbit's inbox, with Undo.
/// Orbit hides the messages at once and applies the change on the server;
/// Undo restores both. Exeter mail has no server action, so it's just hidden.
extension AppModel {
    func archive(_ digests: [StoredEmailDigest]) { organise(digests, .archive) }
    func trash(_ digests: [StoredEmailDigest]) { organise(digests, .trash) }

    private func organise(_ digests: [StoredEmailDigest], _ action: MailboxAction) {
        let targets = digests.filter { !$0.handled }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        for d in targets { d.handled = true }
        context.saveQuietly()
        send(action, ids: ids)
        let noun = targets.count == 1 ? "“\(targets[0].subject)”" : "\(targets.count) emails"
        show("\(action.pastTense): \(noun)", undo: { [weak self] in
            guard let self else { return }
            for d in targets { d.handled = false }
            self.context.saveQuietly()
            self.send(action.inverse, ids: ids)
        })
    }

    private func send(_ action: MailboxAction, ids: [String]) {
        Task { @MainActor in
            do {
                try await backend.mailAction(action, digestIDs: ids)
            } catch {
                show("Gmail didn't update: \(error.localizedDescription)")
            }
        }
    }
}

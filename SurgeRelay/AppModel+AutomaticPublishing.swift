import Foundation

@MainActor
extension AppModel {
    func scheduleAutomaticPublish() {
        let admission = AutomaticPublishPlanner.scheduleAdmission(
            context: automaticPublishContext(),
            plan: githubPublishPlan
        )
        guard admission.isAccepted else {
            applyAutomaticPublishAdmission(admission)
            return
        }
        automaticPublishTask?.cancel()
        let scheduledAt = Date.now
        automaticPublishScheduledAt = scheduledAt
        automaticPublishRunsAt = scheduledAt.addingTimeInterval(TimeInterval(Self.automaticPublishDelaySeconds))
        automaticPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.automaticPublishDelaySeconds))
            guard !Task.isCancelled, let self else { return }
            while self.isWorking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            let runAdmission = AutomaticPublishPlanner.runAdmission(
                context: self.automaticPublishContext(),
                plan: self.githubPublishPlan,
                hasCachedStandaloneOutput: await self.hasAnyCachedGitHubStandaloneOutput()
            )
            guard runAdmission.isAccepted else {
                self.applyAutomaticPublishAdmission(runAdmission)
                return
            }
            self.clearAutomaticPublishSchedule()
            self.beginWork(.automaticPublishing)
            defer {
                self.endWork(.automaticPublishing)
                self.automaticPublishTask = nil
            }
            do {
                guard self.shouldContinueCurrentWork() else { return }
                let preview = try await self.githubPublishPreview()
                guard self.shouldContinueCurrentWork() else { return }
                if preview.requiresDeletionConfirmation {
                    self.pendingPublishPreview = preview
                    self.statusMessage = GitHubPublishPlanner.automaticDeletionConfirmationStatus(
                        deletedFileCount: preview.deletedFiles.count
                    )
                    return
                }
                let report = try await self.publishAllInternal()
                guard self.shouldContinueCurrentWork() else { return }
                self.statusMessage = GitHubPublishPlanner.automaticReportStatus(report)
                self.recordGitHubPublish(report)
            } catch {
                guard !self.isCurrentWorkCancellation(error) else { return }
                if GitHubPublishPlanner.isNoFilesToPublish(error) {
                    self.statusMessage = AutomaticPublishPlanner.noStandaloneFilesStatus
                    return
                }
                self.presentedError = "GitHub 自动发布失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelAutomaticPublishSchedule() {
        if workActivity.kind == .automaticPublishing, !workActivity.canCancel {
            clearAutomaticPublishSchedule()
            return
        }
        automaticPublishTask?.cancel()
        automaticPublishTask = nil
        clearAutomaticPublishSchedule()
    }

    func clearAutomaticPublishSchedule() {
        automaticPublishScheduledAt = nil
        automaticPublishRunsAt = nil
    }

    func automaticPublishContext() -> AutomaticPublishContext {
        AutomaticPublishPlanner.context(
            settings: settings,
            tokenIsAvailable: !ensureGitHubTokenLoaded(showStatusMessage: false).isEmpty
        )
    }

    private func applyAutomaticPublishAdmission(_ admission: AutomaticPublishAdmission) {
        if admission.shouldClearSchedule {
            clearAutomaticPublishSchedule()
        }
        if let statusMessage = admission.statusMessage {
            self.statusMessage = statusMessage
        }
    }

    private func hasAnyCachedGitHubStandaloneOutput() async -> Bool {
        await AutomaticPublishPlanner.hasAnyCachedStandaloneOutput(
            plan: githubPublishPlan
        ) { [fileStore] id in
            await fileStore.hasComponent(id: id)
        }
    }
}

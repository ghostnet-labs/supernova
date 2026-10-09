import Foundation

@MainActor enum CoordinatorRegistry {
    private static var stores: [String: Coordinator] = [:]
    static func store(context: ManagedConversationContext, database: AgentDatabase) -> Coordinator {
        let key = database.url.path + "|" + context.projectID
        if let existing = stores[key] { existing.updateContext(context); return existing }
        let coordinator = Coordinator(context: context, database: database)
        stores[key] = coordinator
        ManagedConversationRegistry.shutdownHooks[key] = { await coordinator.shutdown() }
        return coordinator
    }
    static func attach(parent: ManagedConversationStore) -> Coordinator {
        let coordinator = store(context: parent.context, database: parent.database)
        coordinator.bindParent(CoordinatorParentLink(threadID: { [weak parent] in parent?.threadID }, turnID: { [weak parent] in parent?.activeTurnID }, humanMessageID: { [weak parent] in parent?.currentDispatchID }, isIdle: { [weak parent] in parent?.canSend == true }, sendResult: { [weak parent] id, text in
            guard let parent else { return false }
            return try await parent.sendResult(resultID: id, text: text)
        }, interrupt: { [weak parent] in await parent?.interrupt() }))
        parent.configureTools(definitions: coordinator.definitions, handler: { [weak coordinator] request in
            guard let coordinator else { return Coordinator.toolResult(false, "Project coordinator is unavailable.") }
            return await coordinator.handleTool(request)
        })
        parent.onHumanDispatch = { [weak coordinator] id, text in coordinator?.authorizeHumanDispatch(messageID: id, instruction: text) }
        parent.onIdle = { [weak coordinator] in Task { await coordinator?.deliverResults() } }
        return coordinator
    }
}

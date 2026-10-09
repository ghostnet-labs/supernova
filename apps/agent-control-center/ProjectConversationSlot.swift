import SwiftUI
import AppKit

struct ProjectConversationSlot: View {
    let context: ManagedConversationContext
    let database: AgentDatabase
    var body: some View {
        let store = ManagedConversationRegistry.store(context: context, database: database)
        ManagedConversationView(store: store, coordinator: CoordinatorRegistry.attach(parent: store))
    }
}

private struct ManagedConversationView: View {
    @ObservedObject var store: ManagedConversationStore
    @ObservedObject var coordinator: Coordinator
    @State private var draft = ""
    @State private var confirmNew = false
    @State private var showSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Coordinator", systemImage: "bubble.left.and.bubble.right") .font(.headline)
                Text(store.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.threadID != nil || store.needsReconciliation {
                    Button("Reconnect / reconcile") { Task { await store.reconcile() } }.disabled(store.isBusy)
                }
                Button("Settings", systemImage: "info.circle") { showSettings.toggle() }
                Button("New conversation") { confirmNew = true }.disabled(store.activeTurnID != nil || store.isBusy)
            }
            if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !store.activity.isEmpty { Text(store.activity).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
            if store.needsReconciliation {
                Text("The last request may have reached Codex. Reconcile its saved history before continuing; it will not be sent again automatically.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if showSettings {
                Text(store.effectiveSettings == .null ? "Uses the installed Codex CLI’s authentication, model, effort and permissions. The control process starts when you send a message or reconnect." : store.effectiveSettings.text)
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if store.historyCursor != nil { Button("Load older messages") { Task { await store.loadOlder() } }.disabled(store.isBusy) }
                        if store.messages.isEmpty {
                            ContentUnavailableView("Project conversation", systemImage: "bubble.left.and.text.bubble.right", description: Text("Ask a question or describe work for this project. Retrieved project memory is supplied as evidence."))
                        }
                        ForEach(store.messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "You" : (message.role == "task" ? "Task result" : "Codex")).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10).background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).id(message.id)
                        }
                        ForEach(store.requests) { request in
                            ManagedRequestView(request: request, item: store.approvalItems[request.params["itemId"].string ?? ""] ?? .null, submit: { result in store.respond(request, result: result) })
                        }
                    }.padding(4)
                }.onChange(of: store.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            DelegationControls(coordinator: coordinator)
            HStack(alignment: .bottom) {
                TextField("Message this project’s coordinator", text: $draft, axis: .vertical).lineLimit(2...7)
                    .textFieldStyle(.roundedBorder).disabled(store.needsReconciliation)
                if store.activeTurnID != nil {
                    Button("Steer") { submit(steer: true) }.disabled(!store.canSteer || draft.isEmpty)
                    Button("Interrupt") { Task { await store.interrupt() } }.disabled(!store.canInterrupt)
                } else {
                    Button("Send") { submit(steer: false) }.keyboardShortcut(.return, modifiers: .command).disabled(!store.canSend || draft.isEmpty || draft.utf8.count > 65_536)
                }
            }
        }.padding().task { await coordinator.load(); await store.load() }
        .confirmationDialog("Start a new conversation?", isPresented: $confirmNew) {
            Button("Start new conversation") { Task { await store.newConversation() } }
        } message: { Text("The previous thread remains in Codex history. Any unknown request must be inspected there before you repeat its work.") }
    }
    private func submit(steer: Bool) {
        let text = draft
        Task { await store.send(text, steer: steer); if store.error == nil { draft = "" } }
    }
}

/// Render provider choices exactly and return their original JSON, including explicit persistent amendments.
struct ManagedRequestView: View {
    let request: AppServerRequest
    let item: RPCValue
    let submit: (RPCValue) -> Void
    @State private var answers: [String: String] = [:]
    @State private var form = "{}"
    @State private var formError: String?
    private var params: RPCValue { request.params }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "person.crop.circle.badge.questionmark").font(.headline)
            Text("Thread \(request.threadID ?? "unknown") · Turn \(request.turnID ?? "current")").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let reason = params["reason"].string ?? params["message"].string { Text(reason).textSelection(.enabled) }
            switch request.method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                if let command = params["command"].string { Text(command).font(.body.monospaced()).textSelection(.enabled) }
                if let cwd = params["cwd"].string { Text(cwd).font(.caption).textSelection(.enabled) }
                if params["additionalPermissions"] != .null { Text(params["additionalPermissions"].text).font(.caption.monospaced()).textSelection(.enabled) }
                if let root = params["grantRoot"].string { Text("Requested write access: \(root)").textSelection(.enabled) }
                if !item["changes"].array.isEmpty {
                    ForEach(Array(item["changes"].array.enumerated()), id: \.offset) { _, change in
                        Text(change["path"].string ?? "File change").font(.caption.bold()).textSelection(.enabled)
                        ScrollView([.horizontal, .vertical]) { Text(String((change["diff"].string ?? "Diff unavailable").prefix(65_536))).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 150)
                    }
                }
                ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                    Button(label(decision)) { submit(.object(["decision": decision])) }
                }
            case "item/permissions/requestApproval":
                Text(params["permissions"].text).font(.body.monospaced()).textSelection(.enabled)
                Button("Allow requested permissions for this turn") { submit(.object(["permissions": params["permissions"], "scope": .string("turn")])) }
                Button("Decline") { submit(.object(["permissions": .object([:]), "scope": .string("turn")])) }
            case "item/tool/requestUserInput":
                ForEach(Array(params["questions"].array.enumerated()), id: \.offset) { _, question in
                    let key = question["id"].string ?? ""
                    Text(question["question"].string ?? "Question")
                    ForEach(Array(question["options"].array.enumerated()), id: \.offset) { _, option in
                        Button(option["label"].string ?? "Option") { answers[key] = option["label"].string ?? "" }
                            .help(option["description"].string ?? "")
                    }
                    if question["isSecret"] == .bool(true) { SecureField("Answer", text: binding(key)) }
                    else { TextField("Answer", text: binding(key)) }
                }
                Button("Submit answers") {
                    submit(.object(["answers": .object(answers.mapValues { .object(["answers": .array([.string($0)])]) })]))
                }.disabled(params["questions"].array.contains { (answers[$0["id"].string ?? ""] ?? "").isEmpty })
            case "mcpServer/elicitation/request":
                if let raw = params["url"].string, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") { Link("Open requested authorization page", destination: url) }
                if params["requestedSchema"] != .null {
                    Text(params["requestedSchema"].text).font(.caption.monospaced()).textSelection(.enabled)
                    TextField("Response JSON", text: $form, axis: .vertical).lineLimit(2...8)
                    Button("Submit form") {
                        do {
                            let value = try JSONDecoder().decode(RPCValue.self, from: Data(form.utf8))
                            guard case .object = value else { throw AgentStorageError.invalid("Enter a JSON object matching the requested form.") }
                            submit(.object(["action": .string("accept"), "content": value]))
                        } catch { formError = error.localizedDescription }
                    }
                }
                Button("Decline") { submit(.object(["action": .string("decline"), "content": .null])) }
                Button("Cancel") { submit(.object(["action": .string("cancel"), "content": .null])) }
                if let formError { Text(formError).foregroundStyle(.red) }
            default:
                Text("This request type is not supported by this installed adapter. Interrupt the turn to cancel it.").foregroundStyle(.orange)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
    private var title: String {
        switch request.method {
        case "item/commandExecution/requestApproval": return "Command approval"
        case "item/fileChange/requestApproval": return "File change approval"
        case "item/permissions/requestApproval": return "Additional permissions"
        default: return "Your input is needed"
        }
    }
    private var decisions: [RPCValue] {
        if case .array(let offered) = params["availableDecisions"] { return offered }
        return [.string("accept"), .string("acceptForSession"), .string("decline"), .string("cancel")]
    }
    private func label(_ value: RPCValue) -> String {
        switch value.string {
        case "accept": return "Allow once"
        case "acceptForSession": return "Allow for this session"
        case "decline": return "Decline"
        case "cancel": return "Cancel turn"
        default: return value.text
        }
    }
    private func binding(_ key: String) -> Binding<String> { Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 }) }
}

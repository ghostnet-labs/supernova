import SwiftUI

private struct TimelineElapsed: View {
    let start: Date
    var prefix = ""
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(prefix + timelineDuration(context.date.timeIntervalSince(start))).monospacedDigit()
        }
    }
}

struct ConversationTurnHeader: View {
    let turn: TimelineTurn
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let duration = turn.duration {
                Text("\(turn.terminal?.kind == .taskAborted ? "Stopped after" : "Worked for") \(timelineDuration(duration))")
            } else if active {
                TimelineElapsed(start: turn.startedAt, prefix: "Working for ")
            } else {
                Text("Response")
            }
            Rectangle().fill(AppTheme.separator.opacity(0.65)).frame(height: 0.5)
        }
        .font(AppFont.callout).foregroundStyle(.secondary)
        .padding(.top, 24).padding(.bottom, 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.turn.\(turn.id)")
        .help(turn.startedAt.formatted())
    }
}

struct ActivityGroupView: View {
    let events: [TimelineEvent]
    let path: URL
    let activeTurns: Set<String>
    let verbose: Bool
    @State private var expanded = false

    var body: some View {
        let tools = events.filter { $0.kind == .tool }
        let pending = tools.filter { $0.outputOffset == nil && activeTurns.contains($0.turnID) }.count
        let failures = tools.filter(\.failed).count
        if verbose || tools.count <= 1 {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events) { event in
                    TimelineEventRow(event: event, path: path, active: activeTurns.contains(event.turnID))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: failures > 0 ? "exclamationmark.circle" : "terminal")
                            .foregroundStyle(failures > 0 ? AppTheme.error : Color.secondary)
                        Text("\(tools.count) tool calls")
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(AppFont.caption2)
                        Spacer()
                        if failures > 0 { Text("\(failures) failed").foregroundStyle(AppTheme.error) }
                        else if pending > 0 { Text("\(pending) running") }
                        else if tools.contains(where: { $0.outputOffset == nil }) { Text("Result not recorded") }
                    }
                    .font(AppFont.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activity-group-\(events[0].id)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(events) { event in
                            TimelineEventRow(event: event, path: path, active: activeTurns.contains(event.turnID))
                        }
                    }.padding(.leading, 22)
                }
            }
        }
    }
}

struct TimelineEventRow: View {
    let event: TimelineEvent
    let path: URL
    let active: Bool
    @State private var expanded = false

    var body: some View {
        if event.kind == .tool {
            VStack(alignment: .leading, spacing: 10) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: event.failed ? "exclamationmark.circle" : "terminal")
                            .foregroundStyle(event.failed ? AppTheme.error : Color.secondary)
                        Text(ToolDisplay.title(event.label)).lineLimit(1).layoutPriority(1)
                        if !event.detail.isEmpty {
                            Text(verbatim: event.detail).font(AppFont.system(size: 12, design: .monospaced))
                                .fontDesign(.monospaced).lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        if event.failed { Text("Failed").foregroundStyle(AppTheme.error) }
                        else if event.outputOffset == nil && !active { Text("No result") }
                        if let end = event.endedAt {
                            Text(timelineDuration(end.timeIntervalSince(event.timestamp)))
                        } else if active && event.outputOffset == nil {
                            TimelineElapsed(start: event.timestamp)
                        }
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(AppFont.caption2)
                    }
                    .font(AppFont.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ToolDisplay.title(event.label))
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("timeline-event-\(event.id)")
                .help("\(event.label) · \(event.timestamp.formatted())")
                if expanded {
                    TimelineEventDetails(event: event, path: path).padding(12)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: timelineSymbol(event.kind)).foregroundStyle(timelineColor(event.kind))
                Text(event.label)
                if let duration = event.duration { Text("· " + timelineDuration(duration)) }
                else if event.kind == .taskStarted && active { TimelineElapsed(start: event.timestamp) }
            }
            .font(AppFont.caption2).foregroundStyle(.secondary).padding(.vertical, 2)
            .help(event.timestamp.formatted())
        }
    }
}

private struct TimelineEventDetails: View {
    let event: TimelineEvent
    let path: URL
    @State private var payload: TimelinePayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let payload {
                CodeBlock(text: payload.input, title: "Input", maxHeight: 240)
                if let output = payload.output { CodeBlock(text: output, title: "Output", maxHeight: 300) }
            } else {
                Text("Loading details…").font(AppFont.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: event.outputOffset) {
            let path = path, event = event
            let result = await Task.detached(priority: .utility) { TimelinePayload.load(path: path, event: event) }.value
            guard !Task.isCancelled else { return }
            payload = result
        }
    }
}

import SwiftUI

private struct TimelineElapsed: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(timelineDuration(context.date.timeIntervalSince(start))).monospacedDigit()
        }
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
            VStack(alignment: .leading, spacing: 10) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                        Image(systemName: failures > 0 ? "exclamationmark.circle" : "terminal")
                            .foregroundStyle(failures > 0 ? AppTheme.error : Color.secondary)
                        Text("\(tools.count) tool calls").font(.caption.weight(.medium))
                        Spacer()
                        if failures > 0 { Text("\(failures) failed").foregroundStyle(AppTheme.error) }
                        else if pending > 0 { Text("\(pending) awaiting result").foregroundStyle(AppTheme.accent) }
                        else { Text(tools.allSatisfy { $0.outputOffset != nil } ? "Finished" : "Result not recorded").foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                    .padding(11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activity-group-\(events[0].id)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(events) { event in
                            TimelineEventRow(event: event, path: path, active: activeTurns.contains(event.turnID))
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.separator.opacity(0.4), lineWidth: 0.5))
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
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).padding(.top, 3)
                        Image(systemName: event.failed ? "exclamationmark.circle" : "terminal")
                            .foregroundStyle(event.failed ? AppTheme.error : Color.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(ToolDisplay.title(event.label)).font(.caption.weight(.medium))
                                Spacer(minLength: 0)
                                Text(event.failed ? "Failed" : event.outputOffset != nil ? "Returned" : active ? "Awaiting result" : "No result")
                                    .foregroundStyle(event.failed ? AppTheme.error : Color.secondary)
                                if let end = event.endedAt {
                                    Text(timelineDuration(end.timeIntervalSince(event.timestamp))).foregroundStyle(.secondary)
                                } else if active { TimelineElapsed(start: event.timestamp).foregroundStyle(.secondary) }
                            }
                            .font(.caption2)
                            if !event.detail.isEmpty {
                                Text(verbatim: event.detail).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ToolDisplay.title(event.label))
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("timeline-event-\(event.id)")
                .help("\(event.label) · \(event.timestamp.formatted())")
                if expanded {
                    TimelineEventDetails(event: event, path: path).padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 6) {
                Image(systemName: timelineSymbol(event.kind)).foregroundStyle(timelineColor(event.kind))
                Text(event.label)
                if let duration = event.duration { Text("· " + timelineDuration(duration)) }
                else if event.kind == .taskStarted && active { TimelineElapsed(start: event.timestamp) }
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 2)
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
                Text("Loading details…").font(.caption).foregroundStyle(.secondary)
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

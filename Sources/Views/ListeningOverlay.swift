import AppKit
import SwiftUI

@MainActor
final class ListeningOverlay {
    private var panel: ListeningPanel?
    private static let panelSize = NSSize(width: 108, height: 60)

    func show(appState: AppState) {
        let panel: ListeningPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = ListeningPanel(
                contentRect: NSRect(origin: .zero, size: Self.panelSize),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ListeningPill(appState: appState))
            self.panel = panel
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - Self.panelSize.width / 2, y: frame.minY + 12,
                                  width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private final class ListeningPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ListeningPill: View {
    let appState: AppState

    private var tint: Color {
        if case .error = appState.state { return .red }
        return appState.isRecording ? .white : .white.opacity(0.45)
    }

    var body: some View {
        StationaryWaveform(level: appState.audioLevels.last ?? 0, tint: tint)
        .shadow(color: tint.opacity(0.3), radius: 2)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.black, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        .padding(10)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel(appState.isRecording ? "Listening — microphone audio level" : "Finishing dictation")
    }
}

private struct StationaryWaveform: View {
    let level: Float
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Bar: Identifiable {
        let id = UUID()
        let strength: CGFloat
    }

    // Created once: each bar keeps its position and identity across microphone updates.
    private static let bars: [Bar] = [CGFloat](arrayLiteral:
        0.22, 0.36, 0.55, 0.4, 0.72, 0.95, 0.64, 1, 0.8,
        0.8, 1, 0.64, 0.95, 0.72, 0.4, 0.55, 0.36, 0.22
    ).map { Bar(strength: $0) }

    var body: some View {
        let amplitude = CGFloat(min(1, pow(max(0, level), 0.65) * 1.2))
        HStack(alignment: .center, spacing: 1) {
            ForEach(Self.bars) { bar in
                Capsule()
                    .fill(tint)
                    .frame(width: 2.3, height: max(3, amplitude * bar.strength * 26))
            }
        }
        .frame(width: 60, height: 26)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
    }
}

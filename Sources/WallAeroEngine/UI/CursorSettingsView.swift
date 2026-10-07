import QuartzCore
import SwiftUI

/// Plays a cursor's frames in a loop, keeping pixel art crisp. Static cursors show their frame.
///
/// The animation is a Core Animation keyframe animation, run by the window server: SwiftUI does
/// not redraw anything per frame, so the previews cost the app almost no CPU.
struct AnimatedCursorImage: NSViewRepresentable {
    let frames: [CGImage]
    let durations: [Double]

    func makeNSView(context: Context) -> CursorAnimationView {
        CursorAnimationView()
    }

    func updateNSView(_ view: CursorAnimationView, context: Context) {
        view.play(frames: frames, durations: durations)
    }
}

final class CursorAnimationView: NSView {
    private let imageLayer = CALayer()
    private var shownFrames: [CGImage] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .nearest // pixel-art cursors stay sharp
        imageLayer.minificationFilter = .nearest
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func play(frames: [CGImage], durations: [Double]) {
        // SwiftUI calls this on every update of the settings; restart only for new frames.
        guard frames.count != shownFrames.count || !zip(frames, shownFrames).allSatisfy({ $0 === $1 }) else { return }
        shownFrames = frames
        imageLayer.removeAnimation(forKey: "frames")
        imageLayer.contents = frames.first

        let timed = Array(durations.prefix(frames.count))
        let total = timed.reduce(0, +)
        guard frames.count > 1, timed.count == frames.count, total > 0 else { return }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        // Discrete key times: one per frame where it starts, plus the closing 1.
        var start = 0.0
        var keyTimes: [NSNumber] = []
        for duration in timed {
            keyTimes.append(NSNumber(value: start / total))
            start += duration
        }
        keyTimes.append(1)
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        imageLayer.add(animation, forKey: "frames")
    }
}

/// The "Cursor" section of the Settings window.
struct CursorSettingsSection: View {
    @EnvironmentObject private var cursor: CursorSettings

    var body: some View {
        Section {
            LabeledContent("Cursor pack") {
                HStack(spacing: 8) {
                    if let name = cursor.folderName {
                        Text(name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Button(cursor.folderName == nil ? "Choose Folder…" : "Change…") {
                        cursor.chooseFolder()
                    }
                }
            }

            if !cursor.previews.isEmpty {
                // A grid that wraps, not a horizontal strip: a mouse wheel scrolls only up and
                // down, so cursors past the edge of a strip could not be reached with a mouse.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8, alignment: .top)], spacing: 12) {
                    ForEach(cursor.previews) { item in
                        VStack(spacing: 4) {
                            AnimatedCursorImage(frames: item.frames, durations: item.durations)
                                .frame(width: 36, height: 36)
                            Text(item.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, 4)

                HStack {
                    Button("Apply", action: cursor.apply)
                        .buttonStyle(.borderedProminent)
                        .disabled(cursor.mappedCount == 0)
                    if cursor.isApplied {
                        Button("Reset", action: cursor.reset)
                    }
                    Spacer()
                }
            }

            if let status = cursor.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Cursor")
        }
    }
}

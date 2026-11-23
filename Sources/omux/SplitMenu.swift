import AppKit
import SwiftUI

/// The split button's menu, built as an `NSMenu` and shown with `popUp`.
///
/// SwiftUI's `Menu` opens on the press and then tracks it: releasing anywhere but inside the
/// menu closes it again. The menu opens a dozen points below the pointer, and where the window
/// sits near a screen edge the menu is pushed sideways as well, so the release almost always
/// landed outside it and the menu appeared to flash and vanish. `popUp` doesn't track the press
/// — the menu stays up until something is picked, or the person clicks away or presses escape.
enum SplitMenu {
    /// What the menu offers: two ways to split off a shell, then the project's other sessions.
    struct Model {
        var others: [(name: String, id: UUID)] = []
        var onShell: (Axis) -> Void = { _ in }
        var onBeside: (UUID) -> Void = { _ in }
    }

    static func build(_ model: Model) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem(title: "New Shell to the Right") { model.onShell(.horizontal) })
        menu.addItem(ActionItem(title: "New Shell Below") { model.onShell(.vertical) })
        guard !model.others.isEmpty else { return menu }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Show beside this session", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for other in model.others {
            menu.addItem(ActionItem(title: other.name) { model.onBeside(other.id) })
        }
        return menu
    }

    /// A menu item that runs a closure, so the menu needs no separate target object.
    final class ActionItem: NSMenuItem {
        private let run: () -> Void

        init(title: String, run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
            isEnabled = true
        }

        required init(coder: NSCoder) { fatalError("not from a nib") }

        @objc private func fire() { run() }
    }
}

/// An invisible view behind the split button, there to anchor the menu under it.
struct SplitMenuAnchor: NSViewRepresentable {
    final class Holder: ObservableObject { weak var view: NSView? }
    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { holder.view = view }
}

extension SplitMenu {
    /// Under the anchor, so the menu hangs from the button as a menu should. AppKit keeps it on
    /// screen from there, and the pointer never has to reach it for the menu to stay.
    @MainActor static func show(_ model: Model, from holder: SplitMenuAnchor.Holder) {
        guard let view = holder.view else { return }
        build(model).popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: view)
    }
}

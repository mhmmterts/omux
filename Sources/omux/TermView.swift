import AppKit
import os
import SwiftTerm
import SwiftUI

enum TermEvent {
    case bell
    case title(String)
    case directory(String?)
    case exited
    /// OSC 7501: the root record's state, kind and message, plus every other record.
    case status(TabRuntime.StatusState?, kind: String?, message: String?, children: [TabRuntime.StatusChild])
    /// ⌘-click on a file path in the output.
    case openPath(String)
    /// ⌘-click on a web address in the output.
    case openLink(URL)
    /// A desktop notification the program asked for (OSC 9 or OSC 777).
    case notification(title: String?, body: String)
}

/// Receives process callbacks on behalf of a TermView. Kept separate because
/// LocalProcessTerminalView already declares methods with these signatures.
private final class ProcessEvents: LocalProcessTerminalViewDelegate {
    weak var owner: TermView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        owner?.emit(.title(title))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 sends a file:// URL
        let path = directory.flatMap { URL(string: $0)?.path ?? $0 }
        owner?.emit(.directory(path))
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner?.emit(.exited)
        owner?.releaseAfterExit()
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        owner?.emit(.exited)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        let children = records.filter { !$0.id.isEmpty }.map {
            TabRuntime.StatusChild(id: $0.id, state: TabRuntime.StatusState(rawValue: $0.state.rawValue),
                                   kind: $0.kind?.rawValue, message: $0.message, title: $0.title)
        }
        guard let root = records.first(where: { $0.id.isEmpty }) ?? records.last else {
            owner?.emit(.status(nil, kind: nil, message: nil, children: []))
            return
        }
        let state = TabRuntime.StatusState(rawValue: root.state.rawValue)
        owner?.emit(.status(state, kind: root.kind?.rawValue, message: root.message, children: children))
    }
}

final class TermView: LocalProcessTerminalView {
    let tabID: UUID
    var onEvent: ((TermEvent) -> Void)?
    private let events = ProcessEvents()
    private var oscObservation: TerminalOscObservation?
    /// Bumped after every batch of output the terminal applies, on SwiftTerm's parse thread.
    private let outputCounter = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// Changes whenever new output has reached the screen. Views that poll the screen keep the
    /// value they last read at and skip the read when it hasn't moved: an idle session, or one
    /// in a hidden tab, then costs them nothing.
    var outputGeneration: UInt64 { outputCounter.withLock { $0 } }

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                   font: Fonts.terminal(),
                   options: TerminalOptions(scrollback: 5000))
        events.owner = self
        processDelegate = events
        let counter = outputCounter
        setProcessOutputHandler { counter.withLock { $0 &+= 1 } }
        // Option composes the layout's character (⌥Q is "@" on a Turkish layout) and
        // stays Meta only on keys with no character: arrows, ⌥⏎, ⌥⌫, Escape, Tab.
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
        // A terminal's lines are short, so a wheel notch that moves a couple of them covers
        // about as much as one does in a document. At SwiftTerm's own 1.0 a flick through a
        // session crawls; at three it overshoots what you were reading.
        scrollSensitivity = Self.scrollSensitivityDefault
        // SwiftTerm's own scroller never enables itself as output arrives — it publishes the
        // state through a render frame that doesn't come — so its knob is never drawn, in
        // either style. TerminalScrollbar below draws ours from the same public numbers.
        scrollerStyle = .overlay
        hideBuiltInScroller()
        apply(Theme.current)
        registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        // Observed, not handled, so SwiftTerm keeps drawing OSC 9;4 progress itself.
        oscObservation = observeOscEvents { [weak self] event in
            guard let note = Self.notification(code: event.code, payload: event.payload) else { return }
            Task { @MainActor in self?.emit(.notification(title: note.title, body: note.body)) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// How far a notch of the wheel moves the terminal's own scrollback.
    static let scrollSensitivityDefault: CGFloat = 2.0
    /// How many lines a wheel event asks for, and what is left over for the next one. Trackpad
    /// deltas are pixels and are divided by the cell; a mouse wheel already counts in lines.
    static func wheelLines(deltaY: CGFloat, precise: Bool, cellHeight: CGFloat,
                           carried: CGFloat, step: CGFloat = 1) -> (lines: Int, carry: CGFloat) {
        let inLines = precise ? deltaY / max(1, cellHeight) : deltaY
        let wanted = inLines * scrollSensitivityDefault / max(1, step) + carried
        let whole = Int(wanted.rounded(.towardZero))
        return (whole, wanted - CGFloat(whole))
    }

    /// How many lines a program moves for one report it is sent. A TUI typically takes a notch
    /// of the wheel to mean more than a line, so asking it for a line apiece scrolls it several
    /// times too far. Dividing by this is what keeps a turn of the wheel covering the same
    /// distance as it does in the terminal's own scrollback.
    static let alternateReportStep: CGFloat = 3

    /// How long between two reports sent to a program that scrolls itself. Sent together they
    /// arrive in one read and it redraws once, so the burst moves no further than a single
    /// notch. A frame apart, each one lands — which is what makes the speed match the
    /// scrollback's under the same hand.
    static let wheelReportGap: TimeInterval = 1.0 / 90
    /// At most this many lines are owed at once; a flick should not scroll for a second after
    /// the hand has stopped.
    static let maxOwedWheelLines = 40
    private var owedWheel = 0
    private var wheelPacer: Timer?
    private var wheelCarry: CGFloat = 0

    /// Watches the wheel before SwiftTerm does. Its own handler is not open to override, and it
    /// writes a turn of the wheel to a self-scrolling program as one burst of reports, which the
    /// program redraws once and so treats as a single notch. Taking the event here lets the
    /// reports go out spaced instead. Every other case is handed straight back.
    private var wheelWatch: Any?

    /// True when this took the event. Separated from the monitor so it can be read in a test.
    func handleWheel(_ event: NSEvent) -> Bool {
        let state = terminalInputStateSnapshot()
        guard let state, state.isAlternateBuffer, state.mouseMode != .off else {
            wheelCarry = 0
            return false
        }
        let cell = frame.height / CGFloat(max(1, terminalDimensions.rows))
        let (lines, carry) = Self.wheelLines(deltaY: event.scrollingDeltaY,
                                             precise: event.hasPreciseScrollingDeltas,
                                             cellHeight: cell, carried: wheelCarry,
                                             step: Self.alternateReportStep)
        wheelCarry = carry
        if lines != 0 { owe(lines: lines) }
        return true
    }

    private func startWheelWatch() {
        guard wheelWatch == nil else { return }
        wheelWatch = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !self.isHidden else { return event }
            let here = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(here) else { return event }
            return self.handleWheel(event) ? nil : event
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopWheelWatch() : startWheelWatch()
    }

    private func stopWheelWatch() {
        if let wheelWatch { NSEvent.removeMonitor(wheelWatch) }
        wheelWatch = nil
        wheelPacer?.invalidate()
        wheelPacer = nil
        owedWheel = 0
    }

    /// Adds to what the program is owed, turning around if the hand did.
    private func owe(lines: Int) {
        if owedWheel != 0, (owedWheel > 0) != (lines > 0) { owedWheel = 0 }
        let sign = lines > 0 ? 1 : -1
        owedWheel = sign * min(Self.maxOwedWheelLines, abs(owedWheel) + abs(lines))
        guard wheelPacer == nil else { return }
        let timer = Timer(timeInterval: Self.wheelReportGap, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.payOneWheelLine() }
        }
        RunLoop.main.add(timer, forMode: .common)
        wheelPacer = timer
        payOneWheelLine()
    }

    private func payOneWheelLine() {
        guard owedWheel != 0 else {
            wheelPacer?.invalidate()
            wheelPacer = nil
            return
        }
        let up = owedWheel > 0
        owedWheel += up ? -1 : 1
        let size = terminalDimensions
        let col = max(1, size.cols / 2), row = max(1, size.rows / 2)
        send(txt: "\u{1b}[<\(up ? 64 : 65);\(col);\(row)M")
    }

    /// The last `count` lines on screen (and just above it), without trailing blank lines.
    /// For the `omux screen` command.
    func lastLines(_ count: Int) -> [String] {
        guard let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: count)) else { return [] }
        var lines = snapshot.rows.map { row in
            String(row.text.reversed().drop { $0 == " " }.reversed())
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    /// The lines on screen now, including the line a full-screen program is drawing its input
    /// on. `lastLines` reads the scrollback instead, where that line has never been written, so
    /// anything asking what the session is showing this moment asks here.
    func visibleLines() -> [String] {
        guard let snapshot = terminalContentSnapshot(region: .viewport) else { return [] }
        return snapshot.rows.map { String($0.text.reversed().drop { $0 == " " }.reversed()) }
    }

    /// Takes SwiftTerm's own scroller out of the way. Now that a session's conversation lives
    /// in the terminal's buffer, that scroller enables itself and flashes its knob beside the
    /// one omux draws — two handles for one session. It cannot be removed, so it is given no
    /// width: its logic runs on, drawing nothing.
    func hideBuiltInScroller() {
        let theirs = subviews.filter { $0 is NSScroller || $0.identifier?.rawValue == "SwiftTermOverlayScrollerIndicator" }
        guard !theirs.isEmpty else { return }
        // Narrowing them is not enough: their width is held by constraints, which put it back
        // on the next layout, and SwiftTerm unhides them again whenever the view scrolls.
        // Out of the hierarchy they draw nothing, while SwiftTerm keeps its references and
        // goes on setting their values harmlessly.
        let keep = constraints.filter { constraint in
            !theirs.contains { $0 === constraint.firstItem as? NSView || $0 === constraint.secondItem as? NSView }
        }
        let drop = constraints.filter { !keep.contains($0) }
        NSLayoutConstraint.deactivate(drop)
        theirs.forEach { $0.removeFromSuperview() }
    }

    func apply(_ theme: Theme) {
        font = Fonts.terminal()
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        caretColor = theme.foreground
        installColors(theme.palette)
    }

    /// Closed sessions whose shell is still exiting. Released at once, the view stops reading
    /// the PTY but keeps it open until the shell is reaped, and a shell that prints on its way
    /// out (an agent's goodbye, a TUI restoring the screen) then waits forever for that output
    /// to drain: a stuck shell, PTY and thread per close.
    private static var exiting: Set<TermView> = []

    /// Keeps the view reading until its shell exits, or for 30 s at most.
    func keepUntilExit() {
        Self.exiting.insert(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.releaseAfterExit() }
    }

    fileprivate func releaseAfterExit() {
        if Thread.isMainThread { Self.exiting.remove(self) } else { DispatchQueue.main.async { Self.exiting.remove(self) } }
    }

    fileprivate func emit(_ event: TermEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }

    /// ⌘-click: file paths go to the preview panel, folders (app bundles too) are shown in
    /// Finder rather than opened, web addresses go to the session's browser, and everything
    /// else (mail, other apps' links) goes to the system.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let path = Self.filePath(from: link) {
            emit(.openPath(path))
        } else if let folder = Self.filePath(from: link, folders: true) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
        } else if let url = Self.webURL(from: link) {
            emit(.openLink(url))
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }

    /// The address when a link is one a browser shows: http or https, nothing else.
    nonisolated static func webURL(from link: String) -> URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    nonisolated static func filePath(from link: String, folders: Bool = false) -> String? {
        var raw = link.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("file://"), let url = URL(string: raw) { raw = url.path }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else { return nil }
        // Drop trailing punctuation Claude's prose leaves on paths.
        while let last = raw.last, ".,:;)]}'\"".contains(last) { raw.removeLast() }
        var path = (raw as NSString).expandingTildeInPath
        // "Foo.swift:12" and "Foo.swift:12:4", as compilers and agents print locations.
        if !FileManager.default.fileExists(atPath: path),
           let location = path.range(of: #":[0-9]+(:[0-9]+)?\z"#, options: .regularExpression) {
            path = String(path[..<location.lowerBound])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue == folders else { return nil }
        return path
    }

    // MARK: Keys

    /// What a ⌘ key does in the focused terminal on top of SwiftTerm's own handling.
    enum CommandKey: Equatable {
        /// Raw bytes for the program, the shell's own line-editing control keys.
        case send([UInt8])
        case find(NSFindPanelAction)
    }

    /// ⌘⌫, ⌘← and ⌘→ edit the shell's line (^U, ^A, ^E); ⌘F, ⌘G and ⇧⌘G search the
    /// scrollback. Any other modifier added leaves the key alone.
    nonisolated static func commandKey(_ characters: String?, _ flags: NSEvent.ModifierFlags) -> CommandKey? {
        switch (flags.intersection([.command, .option, .control, .shift]), characters?.lowercased()) {
        case (.command, "\u{7f}"): .send([0x15])
        case (.command, String(UnicodeScalar(NSLeftArrowFunctionKey)!)): .send([0x01])
        case (.command, String(UnicodeScalar(NSRightArrowFunctionKey)!)): .send([0x05])
        case (.command, "f"): .find(.showFindPanel)
        case (.command, "g"): .find(.next)
        case ([.command, .shift], "g"): .find(.previous)
        default: nil
        }
    }

    /// Takes a ⌘ key for the focused terminal before the menu sees it, so the keys work in Kitty
    /// keyboard mode too. Called from the app's key monitor: SwiftTerm doesn't let a subclass
    /// override its key handling. The find keys also work while the find bar has focus, the
    /// editing keys only while the terminal itself does, so text fields keep ⌘⌫ and ⌘←.
    static func handle(_ event: NSEvent) -> Bool {
        guard let key = commandKey(event.charactersIgnoringModifiers, event.modifierFlags),
              let responder = event.window?.firstResponder as? NSView,
              let view = sequence(first: responder, next: \.superview).first(where: { $0 is TermView }) as? TermView else {
            return false
        }
        switch key {
        case .send(let bytes):
            guard responder === view else { return false }
            view.send(bytes)
        case .find(let action):
            let item = NSMenuItem()
            item.tag = Int(action.rawValue)
            view.performFindPanelAction(item)
        }
        return true
    }

    /// Empties the screen and the scrollback, then sends ^L so the shell or agent redraws.
    /// The erase is fed to the terminal, not the program, which may not know ^L.
    func clearHistory() {
        feed(text: "\u{1b}[H\u{1b}[2J")
        clearScrollback()
        send([0x0c])
    }

    // MARK: Images and files

    /// ⌘V with files or an image on the clipboard pastes their paths, which Claude Code and
    /// Codex read as attachments. Text pastes as before; an image only wins when there is no text.
    override func paste(_ sender: Any) {
        let board = NSPasteboard.general
        do {
            if let text = try Self.attachmentText(from: board) {
                paste(text)
            } else {
                super.paste(sender)
            }
        } catch {
            NSSound.beep()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        let readable = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || board.canReadObject(forClasses: [NSImage.self, NSFilePromiseReceiver.self], options: nil)
        return readable && sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        do {
            // Photos and browsers hand over a promise of the file, not the file itself.
            if !board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
               let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
                window?.makeFirstResponder(self)
                try receive(promises)
                return true
            }
            guard let text = try Self.attachmentText(from: board, preferText: false) else { return false }
            window?.makeFirstResponder(self)
            paste(text)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Pastes each promised file's path as it arrives, in a folder of its own so names can't collide.
    private func receive(_ promises: [NSFilePromiseReceiver]) throws {
        let dir = Self.attachmentDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { [weak self] url, error in
                if error == nil {
                    self?.paste(Self.shellEscaped([url]) + " ")
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    /// Preserve ordinary text pastes; file URLs and image-only clipboard contents become paths.
    static func attachmentText(from board: NSPasteboard, preferText: Bool = true,
                               directory: URL? = nil) throws -> String? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return shellEscaped(urls) + " "
        }
        if preferText, board.string(forType: .string) != nil { return nil }
        guard let image = NSImage(pasteboard: board) else { return nil }
        return shellEscaped([try save(image, directory: directory)]) + " "
    }

    /// Paths the way a shell, Claude Code and Codex read them: spaces and specials escaped.
    /// Control characters become $'\xNN', so a newline in a name can't end the command.
    nonisolated static func shellEscaped(_ urls: [URL]) -> String {
        urls.map { url in
            url.path.unicodeScalars.map { ch in
                if ch.value < 0x20 || ch.value == 0x7f { return String(format: "$'\\x%02x'", ch.value) }
                return " '\"()[]{}&;|<>$`\\*?#~!".unicodeScalars.contains(ch) ? "\\\(ch)" : String(ch)
            }.joined()
        }.joined(separator: " ")
    }

    private static var attachmentDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omux-paste", isDirectory: true)
    }

    /// Saves a pasted image as PNG under the temporary folder, like the browser's picks.
    private static func save(_ image: NSImage, directory: URL?) throws -> URL {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dir = directory ?? attachmentDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        return url
    }

    /// Types text into the session as a paste, so newlines don't submit it early.
    func paste(_ text: String) {
        if terminalInputStateSnapshot()?.bracketedPasteMode == true {
            send(txt: Self.bracketedPaste(text))
        } else {
            send(txt: text)
        }
    }

    /// Without ESC, text from a file name or a log can't end the paste with its own
    /// ESC[201~ and have the lines after it typed and submitted.
    nonisolated static func bracketedPaste(_ text: String) -> String {
        "\u{1b}[200~" + text.replacingOccurrences(of: "\u{1b}", with: "") + "\u{1b}[201~"
    }

    /// The main buffer's text, scrollback included. Read it here on the main actor;
    /// the parsers below are safe to run on the copy from any thread.
    func scrollbackText() -> String {
        String(data: getBufferAsData(kind: .normal), encoding: .utf8) ?? ""
    }

    /// A desktop notification in an OSC payload: `OSC 9 ; body` (iTerm2) or
    /// `OSC 777 ; notify ; title ; body` (Ghostty, rxvt). Claude Code sends these when its
    /// notification channel is `iterm2` or `ghostty`, for itself and for its plugins.
    nonisolated static func notification(code: Int, payload: [UInt8]) -> (title: String?, body: String)? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        switch code {
        case 9:
            // A number first is a ConEmu command, like 9;4 progress, not a message.
            guard !text.isEmpty, text.range(of: #"^\d+(;|$)"#, options: .regularExpression) == nil else { return nil }
            return (nil, text)
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "notify", !parts[2].isEmpty else { return nil }
            return (parts[1].isEmpty ? nil : String(parts[1]), String(parts[2]))
        default:
            return nil
        }
    }

    /// Local server URLs (localhost, 127.0.0.1, …) in `text`, oldest first.
    nonisolated static func mentionedLocalURLs(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:/[^\s'"<>)\]]*)?"#)
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            var url = String(text[range])
            while let last = url.last, ".,:;".contains(last) { url.removeLast() }
            result.removeAll { $0 == url }
            result.append(url)
        }
        return result
    }

    /// File paths that appear in `text` and still exist, oldest first.
    nonisolated static func mentionedPaths(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?<![\w])(?:~|/)[\w.+@%~/-]+"#)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let path = Self.filePath(from: String(text[range])) else { continue }
            if seen.insert(path).inserted { result.append(path) } else if let i = result.firstIndex(of: path) {
                result.remove(at: i); result.append(path)
            }
        }
        return result
    }

    override nonisolated func bell(source: Terminal) {
        super.bell(source: source)
        DispatchQueue.main.async {
            NSSound.beep()
            self.onEvent?(.bell)
        }
    }
}

/// The scrollbar omux draws down the right of a terminal: a knob whose size is the share of the
/// session you can see and whose place is how far back you are, draggable, with a click in the
/// track moving a screenful. SwiftTerm has the numbers but never enables its own scroller as
/// output arrives, so this reads those numbers itself and asks the terminal to scroll.
final class TerminalScrollbar: NSView {
    static let width: CGFloat = 14
    /// The gap each side of the knob. Narrower under the pointer, so the knob swells a little
    /// when you go for it, as a page's does.
    static let knobInset: CGFloat = 3
    private static let heldKnobInset: CGFloat = 1.5
    private static let leastKnobHeight: CGFloat = 26

    private weak var term: TermView?
    private var poll: Timer?
    /// What was last drawn, so an idle session costs a comparison and no redraw.
    private var shown: (canScroll: Bool, position: Double, thumb: CGFloat) = (false, 1, 1)
    /// A program drawing on the alternate screen — vim, htop — keeps no scrollback, so there
    /// is no position to show and none to set: the bar is a plain handle for its wheel.
    private var onAlternateScreen = false
    /// Where that handle sits, between 0 at the start and 1 at the newest line. Its own
    /// record, since such a program reports nothing.
    private var handle: Double = 1
    /// What the handle covers when there is no length to go by.
    private static let handleShare: CGFloat = 0.25
    /// How far a drag travels before it is worth another notch of the wheel.
    private static let pixelsPerNotch: CGFloat = 3
    /// Sends the program `notches` of wheel, positive up. Replaced in tests.
    var sendWheel: ((Int) -> Void)?
    /// Whether the session is a Claude Code keeping its own full-screen layout. It draws its own
    /// Jump to bottom and holds the request at the top of the view, and it keeps its scroll
    /// position to itself — so a knob beside it can only be a handle that says nothing true
    /// about where in the conversation you are. Better none at all. Other full-screen programs
    /// (vim, htop) draw no such thing, so the handle stays for them. Replaced in tests.
    var claudeDrawsItsOwn: (() -> Bool)?
    /// Where in the knob the drag started, as a distance from the knob's top.
    private var grab: CGFloat?
    private var lastDrag: CGFloat?
    private var hovering = false
    /// How many times the handle has been redrawn because it changed shape. For tests.
    private(set) var redraws = 0
    private var lastKnob: CGRect?

    init(term: TermView) {
        self.term = term
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        poll?.invalidate()
        guard window != nil else { poll = nil; return }
        // The terminal publishes no change notification for its scroll extent, so read it on
        // a timer: three values, and a redraw only when one of them moved.
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        refresh()
    }

    deinit { poll?.invalidate() }

    /// Reads where the terminal is in its own scrollback, and redraws when that moved.
    func refresh() {
        guard let term else { return }
        let alternate = term.terminalInputStateSnapshot()?.isAlternateBuffer ?? false
        if alternate != onAlternateScreen {
            onAlternateScreen = alternate
            handle = 1
            needsDisplay = true
        }
        let state = (canScroll: term.canScroll, position: term.scrollPosition, thumb: term.scrollThumbsize)
        let claudeOwnsIt = onAlternateScreen && (claudeDrawsItsOwn?() ?? false)
        let hide = claudeOwnsIt || (!onAlternateScreen && !state.canScroll)
        if hide != isHidden {
            isHidden = hide
            // The session is laid out around this strip, so it has to be measured again.
            (superview as? TerminalHost.Container)?.place()
        }
        if state != shown {
            shown = state
            needsDisplay = true
        }
        let knobNow = knobRect()
        if knobNow != lastKnob {
            lastKnob = knobNow
            redraws += 1
            needsDisplay = true
        }
    }

    /// The knob's place in the track, or nothing when there is nothing to move. Over the
    /// terminal's own scrollback the size is the share of the session on screen and the place
    /// is how far back it is — the terminal's own numbers, not a guess.
    func knobRect() -> CGRect? {
        guard bounds.height > 0, onAlternateScreen || shown.canScroll else { return nil }
        let inset = (hovering || grab != nil) ? Self.heldKnobInset : Self.knobInset
        let track = bounds.insetBy(dx: inset, dy: Self.knobInset)
        let share = onAlternateScreen ? Self.handleShare : max(0.01, min(1, shown.thumb))
        let place = onAlternateScreen ? handle : shown.position
        let height = max(Self.leastKnobHeight, min(track.height, track.height * share))
        let travel = max(0, track.height - height)
        return CGRect(x: track.minX, y: track.minY + travel * CGFloat(place),
                      width: track.width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let knob = knobRect() else { return }
        NSColor.labelColor.withAlphaComponent(hovering || grab != nil ? 0.55 : 0.3).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }

    // The knob is thin, so it answers to the whole strip's width; with nothing to scroll the
    // strip lets clicks through to the terminal under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        knobRect() == nil ? nil : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard let knob = knobRect() else { return }
        let point = convert(event.locationInWindow, from: nil)
        if knob.contains(point) {
            grab = point.y - knob.minY
            lastDrag = point.y
        } else if onAlternateScreen {
            wheel(byPoints: point.y < knob.minY ? -knob.height : knob.height)
        } else {
            // A click in the track moves a screenful towards it, as a page's scrollbar does.
            let screenful = Double(shown.thumb)
            let towards = point.y < knob.minY ? -screenful : screenful
            term?.scroll(toPosition: max(0, min(1, shown.position + towards)))
            refresh()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard grab != nil, let knob = knobRect() else { return }
        let point = convert(event.locationInWindow, from: nil)
        let track = bounds.insetBy(dx: Self.knobInset, dy: Self.knobInset)
        let travel = max(0, track.height - knob.height)
        guard travel > 0, let grab else { return }
        let place = Double(max(0, min(1, (point.y - grab - track.minY) / travel)))
        if onAlternateScreen {
            // Nothing to set: the program keeps the position. The drag becomes wheel travel,
            // and the handle holds where it was left.
            let moved = point.y - (lastDrag ?? point.y)
            lastDrag = point.y
            wheel(byPoints: moved)
            handle = place
            needsDisplay = true
            return
        }
        term?.scroll(toPosition: place)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        grab = nil
        lastDrag = nil
        needsDisplay = true
    }

    /// Turns a travel in points into notches of the wheel for a program that scrolls itself.
    func wheel(byPoints points: CGFloat) {
        let notches = -Int((points / Self.pixelsPerNotch).rounded())
        guard notches != 0 else { return }
        send(notches: notches)
    }

    private func send(notches: Int) {
        if let sendWheel {
            sendWheel(notches)
            return
        }
        guard let term else { return }
        let state = term.terminalInputStateSnapshot()
        guard let state, state.mouseMode != .off else { return sendAsEvents(notches) }
        let size = term.terminalDimensions
        let col = max(1, size.cols / 2), row = max(1, size.rows / 2)
        let button = notches > 0 ? 64 : 65
        let report = "\u{1b}[<\(button);\(col);\(row)M"
        term.send(txt: String(repeating: report, count: min(abs(notches), 400)))
    }

    private func sendAsEvents(_ notches: Int) {
        guard let term, let source = CGEventSource(stateID: .hidSystemState) else { return }
        let step = notches > 0 ? 1 : -1
        for _ in 0..<min(abs(notches), 60) {
            guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                       wheelCount: 1, wheel1: Int32(step), wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: scroll) else { return }
            term.scrollWheel(with: event)
        }
    }
}

/// A microphone over the terminal's bottom corner, where a full-screen program draws its own
/// input line. omux has no box of its own there to put a button in, and it cannot draw inside
/// the program's screen, so the button floats above it and hands the program macOS dictation:
/// what you say is typed into whatever has the keyboard, which is that input line.
final class TerminalDictationButton: NSView {
    static let size: CGFloat = 30
    /// A rounded square, like the window's other small buttons, and large enough to hit
    /// without aiming.
    private static let corner: CGFloat = 8
    /// Clear of the window's own rounded corner and of the scrollbar beside it.
    static let inset: CGFloat = 6

    /// What a press does: by default it sends the key bound to Claude Code's voice mode,
    /// one press to start, one to send. Replaced in tests.
    var onPress: (() -> Void)?
    /// Sends the keys a press stands for. Set by the pane; without it there is nothing to press.
    var sendKeys: ((String) -> Void)?
    /// What a press sends: the space bar, which is how Claude Code's voice mode waits to be
    /// started — and the only way. `voice:pushToTalk` can be bound to a key of its own in
    /// ~/.claude/keybindings.json, but pressing that key does not start a recording, by hand or
    /// from here: the action wants a key held, not tapped. So a message already part-written
    /// cannot be dictated into; space would only type a space. Editing one ends the dictation
    /// and the rest has to be typed.
    static let tap = " "
    private weak var term: TermView?
    private var hovering = false
    private var watch: Timer?

    init(term: TermView) {
        self.term = term
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "Dictate: starts Claude Code's own voice mode (press again to send)"
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let face = bounds.insetBy(dx: 1, dy: 1)
        if listening {
            NSColor.systemRed.withAlphaComponent(0.22).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(hovering ? 0.16 : 0.08).setFill()
        }
        NSBezierPath(roundedRect: face, xRadius: Self.corner, yRadius: Self.corner).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let mic = NSImage(systemSymbolName: listening ? "waveform" : "mic", accessibilityDescription: "Dictate")?
            .withSymbolConfiguration(config) else { return }
        let strength: CGFloat = hovering ? 0.9 : 0.55
        let tint = NSImage(size: mic.size, flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(strength).set()
            rect.fill(using: .sourceOver)
            mic.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tint.draw(in: CGRect(x: bounds.midX - mic.size.width / 2, y: bounds.midY - mic.size.height / 2,
                             width: mic.size.width, height: mic.size.height))
    }

    override func mouseDown(with event: NSEvent) {
        if let onPress {
            onPress()
            return
        }
        press()
    }

    /// Claude Code's own voice mode, started through the key bound to it. A second press
    /// sends what was said. The keyboard goes back to the session so the next press lands
    /// there too.
    func press() {
        term?.window?.makeFirstResponder(term)
        sendKeys?(Self.tap)
        // Whether that started or ended a recording is the session's to say; the button finds
        // out on its next read, a moment from now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.readState() }
    }

    /// Whether the agent is listening now. Not the button's own count of taps — a message
    /// sent with the return key, or the agent deciding it has heard enough, would leave that
    /// count believing a recording is still running. The agent writes "listening…" on its own
    /// screen while it records, so the button reads the truth there.
    private(set) var listening = false

    /// What the bottom of the session says. Replaced in tests.
    var screenText: (() -> String)?
    /// Whether an agent with a voice mode is running in this session right now. Asked on
    /// every look, not once when the pane was built: an agent started a minute later should
    /// bring the button with it, and one that exits should take it away.
    var agentRunning: (() -> Bool)?

    /// The words the agent shows while it has the microphone.
    static let listeningMarks = ["listening", "transcribing"]

    /// Reads the session's own screen and matches the button to it.
    func readState() {
        let running = agentRunning?() ?? true
        if isHidden != !running {
            isHidden = !running
            needsDisplay = true
        }
        guard running else { return }
        let text = (screenText?() ?? term?.visibleLines().joined(separator: "\n") ?? "").lowercased()
        let now = Self.listeningMarks.contains { text.contains($0) }
        guard now != listening else { return }
        listening = now
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watch?.invalidate()
        guard window != nil else { watch = nil; return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
        readState()
    }

    deinit { watch?.invalidate() }
}

/// Hosts the long-lived TermView for the selected tab. Terminal views are owned by
/// the Store so switching tabs reparents a view instead of recreating the session.
struct TerminalHost: NSViewRepresentable {
    let termView: TermView
    let theme: Theme
    /// Called on a click anywhere in the terminal, before the terminal handles it.
    var onClick: (() -> Void)? = nil
    /// A session dragged over the terminal: the edge it would land on, or nil when it leaves.
    var onDragEdge: ((Edge?) -> Void)? = nil
    /// A session dropped on the terminal, with the edge it landed on.
    var onDropSession: ((UUID, Edge) -> Void)? = nil

    final class Coordinator { var currentID: UUID? }

    /// Notices clicks on the way to the terminal without taking them, and takes sessions
    /// dragged from the sidebar or another pane (AppKit drags, which SwiftUI's own drop
    /// targets don't receive from a List).
    final class Container: NSView {
        var onClick: (() -> Void)?
        var onDragEdge: ((Edge?) -> Void)?
        var onDropSession: ((UUID, Edge) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.string])
        }

        required init?(coder: NSCoder) { fatalError("not supported") }

        /// SwiftUI hands the container its size after the views go in, starting from zero, and
        /// sets that size as a frame rather than through a layout pass — so `layout()` alone
        /// never runs again and the children keep their zero frames. Place them on every size
        /// change as well.
        func place() {
            // A hidden scrollbar takes no room: a Claude Code drawing its own Jump to bottom
            // leaves no knob beside it, and a strip of empty background where one would have
            // been is just a narrower session.
            let bar = subviews.first { $0 is TerminalScrollbar }
            let reserved = (bar?.isHidden ?? false) ? 0 : TerminalScrollbar.width
            let split = bounds.divided(atDistance: reserved, from: .maxXEdge)
            (subviews.first { $0 is TermView } as? TermView)?.hideBuiltInScroller()
            let size = TerminalDictationButton.size, inset = TerminalDictationButton.inset
            for view in subviews {
                if view is TerminalScrollbar {
                    view.frame = split.slice
                } else if view is TerminalDictationButton {
                    // Beside the program's own input line, at the corner it leaves free.
                    view.frame = CGRect(x: split.remainder.maxX - size - inset, y: inset,
                                        width: size, height: size)
                } else if view is TermView {
                    view.frame = split.remainder
                }
            }
        }

        override func layout() {
            super.layout()
            place()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            place()
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            place()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let view = super.hitTest(point)
            if view != nil, let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .rightMouseDown,
               let onClick {
                DispatchQueue.main.async(execute: onClick)
            }
            return view
        }

        private func session(in info: NSDraggingInfo) -> UUID? {
            info.draggingPasteboard.string(forType: .string).flatMap(UUID.init(uuidString:))
        }

        /// The edge nearest to the point, as a share of each side; flipped so top is top.
        private func edge(for info: NSDraggingInfo) -> Edge {
            let p = convert(info.draggingLocation, from: nil)
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return .trailing }
            let y = isFlipped ? p.y : size.height - p.y
            let shares: [(Edge, CGFloat)] = [(.leading, p.x / size.width), (.trailing, 1 - p.x / size.width),
                                             (.top, y / size.height), (.bottom, 1 - y / size.height)]
            return shares.min(by: { $0.1 < $1.1 })?.0 ?? .trailing
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard session(in: sender) != nil else { return [] }
            onDragEdge?(edge(for: sender))
            return .move
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard session(in: sender) != nil else { return [] }
            onDragEdge?(edge(for: sender))
            return .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { onDragEdge?(nil) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let landing = edge(for: sender)
            onDragEdge?(nil)
            guard let id = session(in: sender) else { return false }
            onDropSession?(id, landing)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        container.onClick = onClick
        container.onDragEdge = onDragEdge
        container.onDropSession = onDropSession
        container.layer?.backgroundColor = theme.background.cgColor
        // Under a transcript the terminal keeps its size and screen but doesn't draw.
        let visible = context.environment.terminalVisible
        if termView.isHidden == visible { termView.isHidden = !visible }
        guard context.coordinator.currentID != termView.tabID || termView.superview !== container else { return }
        context.coordinator.currentID = termView.tabID
        container.subviews.forEach { $0.removeFromSuperview() }
        // The scrollbar sits beside the terminal rather than over it, so no line of output ends
        // up underneath the knob.
        container.addSubview(termView)
        let scrollbar = TerminalScrollbar(term: termView)
        scrollbar.claudeDrawsItsOwn = { [weak termView] in
            guard Store.claudeFullScreen, let termView,
                  let runtime = Store.shared.runtime[termView.tabID] else { return false }
            return runtime.provider == .claude && !runtime.exited
        }
        container.addSubview(scrollbar)
        // The button goes in whatever the session is doing now; it shows itself only while an
        // agent with a voice mode is actually running there. A session that was Claude Code
        // yesterday and sits in a plain shell today has nothing to tap, and one started a
        // minute from now should bring the button with it.
        let mic = TerminalDictationButton(term: termView)
        mic.agentRunning = { [weak termView] in
            guard let termView, let runtime = Store.shared.runtime[termView.tabID] else { return false }
            // omux already knows this: an agent that is running has connected to omux and
            // reports its state. `provider` alone would not do — it remembers what the
            // session last ran, so a window back at its shell prompt still answers "claude".
            return runtime.provider == .claude && !runtime.exited
                && (runtime.agentConnected || runtime.statusState != nil)
        }
        mic.sendKeys = { [weak termView] keys in
            guard let termView else { return }
            Store.shared.sendKeys(keys, to: termView.tabID)
        }
        container.addSubview(mic)
        container.place()
        if visible {
            DispatchQueue.main.async {
                termView.window?.makeFirstResponder(termView)
            }
        }
    }
}

/// What a view last read the screen at, in a box so that remembering it doesn't redraw the view.
final class ScreenReadMemo<Key: Equatable> {
    var key: Key?

    /// Remembers `key`; false when the last read was already at it, so there's nothing new to read.
    func changed(to key: Key) -> Bool {
        if self.key == key { return false }
        self.key = key
        return true
    }
}

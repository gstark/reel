import AppKit

/// Labeled rows under a file panel or in the remote panel. The labels share a right edge
/// and the controls share a left edge, so rows from different places line up.
class PanelForm: NSView {
    private let grid = NSGridView()

    /// A centered form fits a file panel. A leading form fits the remote panel.
    init(centered: Bool) {
        super.init(frame: .zero)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        let inset: CGFloat = centered ? 12 : 0
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        if centered {
            grid.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor).isActive = true
        } else {
            grid.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Adds a row. Without a label, the control sits under the controls above it.
    func insertRow(at index: Int, label: String?, control: NSView) {
        let labelView = label.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView
        grid.insertRow(at: index, with: [labelView, control])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
    }

    func addRow(label: String?, control: NSView) {
        insertRow(at: grid.numberOfRows, label: label, control: control)
    }

    /// Sets the frame for a file panel accessory: the size of the rows, and at least 480 points wide.
    func fitForPanel() {
        let size = fittingSize
        frame = NSRect(x: 0, y: 0, width: max(size.width, 480), height: size.height)
    }
}

/// The prefix field when frames are exported as PNG files.
/// The example under the field shows the name of the first file, and it follows the typing.
final class FramePrefixView: PanelForm, NSTextFieldDelegate {
    private let field: NSTextField
    private let example = NSTextField(labelWithString: "")
    private let exampleFrame: Int
    private let digits: Int

    /// The typed prefix. A "/" or ":" would make a folder or an invalid name, so it becomes "-".
    var prefix: String {
        field.stringValue.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// The frame number with leading zeros, so it has `digits` digits.
    static func number(_ frame: Int, digits: Int) -> String {
        let text = String(frame)
        return String(repeating: "0", count: max(digits - text.count, 0)) + text
    }

    init(prefix: String, exampleFrame: Int, digits: Int, centered: Bool) {
        field = NSTextField(string: prefix)
        self.exampleFrame = exampleFrame
        self.digits = digits
        super.init(centered: centered)

        field.delegate = self
        field.placeholderString = "No prefix"
        example.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        example.textColor = .secondaryLabelColor
        updateExample()
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        addRow(label: "File name prefix:", control: field)
        addRow(label: nil, control: example)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func controlTextDidChange(_ notification: Notification) {
        updateExample()
    }

    private func updateExample() {
        example.stringValue = "First file: \(prefix)\(Self.number(exampleFrame, digits: digits)).png"
    }
}


import AppKit

/// The prefix field under the folder list when frames are exported as PNG files.
/// The example under the field shows the name of the first file, and it follows the typing.
final class FramePrefixView: NSView, NSTextFieldDelegate {
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

    init(prefix: String, exampleFrame: Int, digits: Int) {
        field = NSTextField(string: prefix)
        self.exampleFrame = exampleFrame
        self.digits = digits
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 64))

        let label = NSTextField(labelWithString: "File name prefix:")
        label.alignment = .right
        field.delegate = self
        field.placeholderString = "No prefix"
        example.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        example.textColor = .secondaryLabelColor
        updateExample()

        let grid = NSGridView(views: [[label, field], [NSGridCell.emptyContentView, example]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 260),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func controlTextDidChange(_ notification: Notification) {
        updateExample()
    }

    private func updateExample() {
        example.stringValue = "First file: \(prefix)\(Self.number(exampleFrame, digits: digits)).png"
    }
}


import AppKit
import LodestoneCore
import LodestoneKit

/// The controls shown in the PDF tools' option dialogs, with accessors for the chosen values.
@MainActor
enum PDFOptionsPanels {
    struct Compression {
        let view: NSView
        let level: () -> PDFCompressionLevel
    }

    static func compression(selected: PDFCompressionLevel) -> Compression {
        let popup = OptionsPanel.popup(PDFCompressionLevel.allCases.map { ($0.rawValue, "\($0.title) — \($0.summary)") }, selected: selected.rawValue)
        let note = OptionsPanel.note(ExternalTool.gs.url != nil
            ? "Compressing with Ghostscript."
            : "Ghostscript isn't installed, so macOS's built-in compression is used. For smaller files, install it with: brew install ghostscript")
        return Compression(view: OptionsPanel.form([("Level:", popup)], footer: note)) {
            PDFCompressionLevel(rawValue: popup.selectedValue ?? "") ?? selected
        }
    }

    struct PageSize {
        let view: NSView
        let values: () -> (PDFPageSize, Int)
    }

    static let marginPresets = [(0, "None"), (18, "Small (¼ inch)"), (36, "Medium (½ inch)"), (72, "Large (1 inch)")]

    static func pageSize(selected: PDFPageSize, margin: Int) -> PageSize {
        let size = OptionsPanel.popup(PDFPageSize.allCases.map { ($0.rawValue, $0.title) }, selected: selected.rawValue)
        var presets = marginPresets
        if !presets.contains(where: { $0.0 == margin }) { presets.append((margin, "\(margin) pt")) }
        let marginPopup = OptionsPanel.popup(presets.map { (String($0.0), $0.1) }, selected: String(margin))
        let note = OptionsPanel.note("A4 and Letter pages turn sideways for landscape images. Large images are scaled down to fit.")
        return PageSize(view: OptionsPanel.form([("Page size:", size), ("Margin:", marginPopup)], footer: note)) {
            (PDFPageSize(rawValue: size.selectedValue ?? "") ?? selected, Int(marginPopup.selectedValue ?? "") ?? margin)
        }
    }

    struct Extract {
        let view: NSView
        let pagesText: () -> String
        let mode: () -> PDFExtractMode
    }

    static func extract(pageCount: Int) -> Extract {
        let field = NSTextField(string: pageCount > 1 ? "1-\(pageCount)" : "1")
        field.placeholderString = "1-3,5,8-"
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let mode = OptionsPanel.popup([
            (PDFExtractMode.combined.rawValue, "All in one PDF"),
            (PDFExtractMode.perRange.rawValue, "One PDF per range"),
            (PDFExtractMode.perPage.rawValue, "One PDF per page"),
        ], selected: PDFExtractMode.combined.rawValue)
        let note = OptionsPanel.note("Pages like 1-3,5,8- (8- runs to the end). Separate ranges with commas; \"One PDF per range\" makes a file for each.")
        return Extract(view: OptionsPanel.form([("Pages:", field), ("Save as:", mode)], footer: note),
                       pagesText: { field.stringValue },
                       mode: { PDFExtractMode(rawValue: mode.selectedValue ?? "") ?? .combined })
    }

    struct Rotate {
        let view: NSView
        let angle: () -> Int
        let pagesText: () -> String
    }

    static func rotate() -> Rotate {
        let angle = OptionsPanel.popup([("90", "90° clockwise"), ("-90", "90° counterclockwise"), ("180", "180°")], selected: "90")
        let field = NSTextField(string: "")
        field.placeholderString = "All pages"
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let note = OptionsPanel.note("Leave Pages empty to rotate every page, or enter pages like 1-3,5.")
        return Rotate(view: OptionsPanel.form([("Rotate:", angle), ("Pages:", field)], footer: note),
                      angle: { Int(angle.selectedValue ?? "") ?? 90 },
                      pagesText: { field.stringValue })
    }

    struct ImageExport {
        let view: NSView
        let values: () -> (PDFImageFormat, Int)
    }

    static func imageExport(format: PDFImageFormat, dpi: Int) -> ImageExport {
        let formatPopup = OptionsPanel.popup([("png", "PNG"), ("jpeg", "JPEG")], selected: format.rawValue)
        var presets = [(72, "72 dpi (screen)"), (150, "150 dpi"), (300, "300 dpi (print)"), (600, "600 dpi")]
        if !presets.contains(where: { $0.0 == dpi }) { presets.append((dpi, "\(dpi) dpi")) }
        let dpiPopup = OptionsPanel.popup(presets.map { (String($0.0), $0.1) }, selected: String(dpi))
        return ImageExport(view: OptionsPanel.form([("Format:", formatPopup), ("Resolution:", dpiPopup)])) {
            (PDFImageFormat(rawValue: formatPopup.selectedValue ?? "") ?? format, Int(dpiPopup.selectedValue ?? "") ?? dpi)
        }
    }
}

import Foundation

/// Renders a transcript as a minimal, valid Office Open XML (`.docx`) document — a paragraph per
/// line, a bold speaker header wherever the speaker changes (mirroring `TranscriptExport`'s
/// markdown grouping), the title as a lead paragraph. Hand-rolled OOXML over `MinimalZip` — no
/// third-party dependency, since a `.docx` is just four small XML parts in a zip container:
/// `[Content_Types].xml` (declares the parts' content types), `_rels/.rels` (the package's root
/// relationship to the document part), `word/document.xml` (the body), and
/// `word/_rels/document.xml.rels` (the document part's own relationships — empty here, since
/// this minimal document references no styles/media/other parts).
enum DocxExporter {
    static func build(_ items: [TranscriptExport.Item], title: String) -> Data {
        let entries = [
            MinimalZip.Entry(name: "[Content_Types].xml", data: Data(contentTypesXML.utf8)),
            MinimalZip.Entry(name: "_rels/.rels", data: Data(packageRelsXML.utf8)),
            MinimalZip.Entry(name: "word/document.xml", data: Data(documentXML(items, title: title).utf8)),
            MinimalZip.Entry(name: "word/_rels/document.xml.rels", data: Data(documentRelsXML.utf8))
        ]
        return MinimalZip.archive(entries)
    }

    // MARK: - Fixed package parts

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let packageRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    </Relationships>
    """

    // MARK: - word/document.xml

    /// Title as a lead paragraph (bold, larger), then one speaker header paragraph per turn
    /// change (bold, plain size) followed by a paragraph per line — same speaker-change
    /// grouping `TranscriptExport.markdown` uses, just rendered as OOXML paragraphs/runs.
    private static func documentXML(_ items: [TranscriptExport.Item], title: String) -> String {
        var body = ""
        if !title.isEmpty {
            body += paragraph(text: title, bold: true, sizeHalfPoints: 32)
        }
        var lastSpeaker: String??
        for item in items {
            if item.speaker != lastSpeaker {
                if let speaker = item.speaker {
                    body += paragraph(text: speaker, bold: true, sizeHalfPoints: nil)
                }
                lastSpeaker = item.speaker
            }
            body += paragraph(text: item.text, bold: false, sizeHalfPoints: nil)
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        \(body)<w:sectPr/>
        </w:body>
        </w:document>
        """
    }

    private static func paragraph(text: String, bold: Bool, sizeHalfPoints: Int?) -> String {
        var runProperties = ""
        if bold { runProperties += "<w:b/>" }
        if let sizeHalfPoints { runProperties += "<w:sz w:val=\"\(sizeHalfPoints)\"/>" }
        let rPr = runProperties.isEmpty ? "" : "<w:rPr>\(runProperties)</w:rPr>"
        return "<w:p><w:r>\(rPr)<w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r></w:p>\n"
    }

    /// Order matters — `&` must be escaped first, or escaping `<`/`>`/`"`/`'` afterward would
    /// re-escape the ampersands their own entities introduce.
    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

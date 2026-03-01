import Foundation

/// Renders Markdown text to a dark-themed PNG image using pandoc + wkhtmltoimage.
public enum MarkdownImageRenderer {

    /// Check if the rendering pipeline is available.
    public static func isAvailable() async -> Bool {
        async let pandoc = ShellCommand.isAvailable("pandoc")
        async let wkhtmltoimage = ShellCommand.isAvailable("wkhtmltoimage")
        let p = await pandoc
        let w = await wkhtmltoimage
        return p && w
    }

    /// Render markdown text to a PNG image.
    /// Returns nil if the pipeline is unavailable or rendering fails.
    public static func renderToImage(markdown: String) async -> Data? {
        guard await isAvailable() else { return nil }

        let tmpDir = NSTemporaryDirectory()
        let id = UUID().uuidString
        let mdPath = (tmpDir as NSString).appendingPathComponent("kanban-code-\(id).md")
        let htmlPath = (tmpDir as NSString).appendingPathComponent("kanban-code-\(id).html")
        let imgPath = (tmpDir as NSString).appendingPathComponent("kanban-code-\(id).png")

        defer {
            try? FileManager.default.removeItem(atPath: mdPath)
            try? FileManager.default.removeItem(atPath: htmlPath)
            try? FileManager.default.removeItem(atPath: imgPath)
        }

        do {
            // Write markdown to temp file
            try markdown.write(toFile: mdPath, atomically: true, encoding: .utf8)

            // Convert markdown → HTML with pandoc
            guard let pandocPath = ShellCommand.findExecutable("pandoc") else { return nil }
            let pandocResult = try await ShellCommand.run(
                pandocPath,
                arguments: ["-f", "gfm", "-t", "html", "--standalone",
                           "--metadata", "title= ",
                           "--css", "/dev/null",
                           mdPath, "-o", htmlPath]
            )
            guard pandocResult.succeeded else { return nil }

            // Inject dark theme CSS into the HTML
            var html = try String(contentsOfFile: htmlPath, encoding: .utf8)
            html = injectDarkTheme(into: html)
            try html.write(toFile: htmlPath, atomically: true, encoding: .utf8)

            // Render HTML → PNG with wkhtmltoimage
            guard let wkhtmlPath = ShellCommand.findExecutable("wkhtmltoimage") else { return nil }
            let imgResult = try await ShellCommand.run(
                wkhtmlPath,
                arguments: ["--quality", "90",
                           "--width", "600",
                           "--disable-smart-width",
                           htmlPath, imgPath]
            )
            guard imgResult.succeeded else { return nil }

            return try Data(contentsOf: URL(fileURLWithPath: imgPath))
        } catch {
            return nil
        }
    }

    /// Inject dark theme CSS into pandoc-generated HTML.
    private static func injectDarkTheme(into html: String) -> String {
        let css = """
        <style>
        body {
            background-color: #1e1e1e;
            color: #e0e0e0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            font-size: 14px;
            line-height: 1.6;
            padding: 16px;
            margin: 0;
            max-width: 600px;
        }
        h1, h2, h3, h4, h5, h6 {
            color: #ffffff;
            margin-top: 1em;
            margin-bottom: 0.5em;
        }
        a { color: #58a6ff; }
        code {
            font-family: "SF Mono", "Menlo", "Monaco", "Courier New", monospace;
            background-color: #2d2d2d;
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 13px;
        }
        pre {
            background-color: #2d2d2d;
            padding: 12px;
            border-radius: 6px;
            overflow-x: auto;
        }
        pre code {
            background: none;
            padding: 0;
        }
        blockquote {
            border-left: 3px solid #444;
            margin-left: 0;
            padding-left: 12px;
            color: #aaa;
        }
        ul, ol { padding-left: 24px; }
        li { margin-bottom: 4px; }
        hr {
            border: none;
            border-top: 1px solid #333;
            margin: 16px 0;
        }
        table {
            border-collapse: collapse;
            width: 100%;
        }
        th, td {
            border: 1px solid #444;
            padding: 6px 10px;
            text-align: left;
        }
        th { background-color: #2d2d2d; }
        </style>
        """

        // Insert CSS before </head> if it exists, otherwise prepend
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            var modified = html
            modified.insert(contentsOf: css, at: range.lowerBound)
            return modified
        }
        return css + html
    }
}

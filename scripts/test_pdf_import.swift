#!/usr/bin/env swift
/// Quick Mac test: extract text from a PDF using PDFKit and run it through
/// the same cleanup the Flutter app would do.
///
/// Usage: swift scripts/test_pdf_import.swift sample-scripts/macbeth_PDF_FolgerShakespeare.pdf

import PDFKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("Usage: swift \(CommandLine.arguments[0]) <pdf-path> [--raw] [--page N]")
    exit(1)
}

let path = CommandLine.arguments[1]
let showRaw = CommandLine.arguments.contains("--raw")
let singlePage: Int? = {
    if let idx = CommandLine.arguments.firstIndex(of: "--page"),
       idx + 1 < CommandLine.arguments.count,
       let n = Int(CommandLine.arguments[idx + 1]) {
        return n
    }
    return nil
}()

let url = URL(fileURLWithPath: path)
guard let doc = PDFDocument(url: url) else {
    print("ERROR: Could not open PDF at \(path)")
    exit(1)
}

print("PDF: \(path)")
print("Pages: \(doc.pageCount)")
print("")

var fullText = ""

if let page = singlePage {
    guard page < doc.pageCount else {
        print("ERROR: Page \(page) out of range (0..\(doc.pageCount - 1))")
        exit(1)
    }
    if let p = doc.page(at: page), let text = p.string {
        fullText = text
        print("=== Page \(page) (\(text.count) chars) ===")
        print(text)
    }
    exit(0)
}

// Extract all pages
for i in 0..<doc.pageCount {
    if let page = doc.page(at: i), let text = page.string {
        fullText += text + "\n"
    }
}

print("Total extracted: \(fullText.count) chars")
print("")

if showRaw {
    print(fullText)
    exit(0)
}

// Simulate what the Flutter app's parser would see.
// Strip FTLN noise, page numbers, running headers.
var cleaned = fullText

// Remove FTLN line numbers (e.g., "FTLN 0042", "FTLN 0043 30")
let ftlnPattern = try! NSRegularExpression(pattern: #"FTLN \d+(\s+\d+)?\n?"#)
cleaned = ftlnPattern.stringByReplacingMatches(
    in: cleaned,
    range: NSRange(cleaned.startIndex..., in: cleaned),
    withTemplate: ""
)

// Remove running headers like "11 Macbeth ACT 1. SC. 2"
let headerPattern = try! NSRegularExpression(pattern: #"^\d+\s+Macbeth\s+ACT \d+\.\s*SC\.\s*\d+\s*$"#, options: .anchorsMatchLines)
cleaned = headerPattern.stringByReplacingMatches(
    in: cleaned,
    range: NSRange(cleaned.startIndex..., in: cleaned),
    withTemplate: ""
)

// Remove bare page numbers
let pageNumPattern = try! NSRegularExpression(pattern: #"^\d{1,3}\s*$"#, options: .anchorsMatchLines)
cleaned = pageNumPattern.stringByReplacingMatches(
    in: cleaned,
    range: NSRange(cleaned.startIndex..., in: cleaned),
    withTemplate: ""
)

// Collapse multiple blank lines
let blankLines = try! NSRegularExpression(pattern: #"\n{3,}"#)
cleaned = blankLines.stringByReplacingMatches(
    in: cleaned,
    range: NSRange(cleaned.startIndex..., in: cleaned),
    withTemplate: "\n\n"
)

print("After cleanup: \(cleaned.count) chars")
print("")

// Count character names (ALL CAPS lines that look like speaker labels)
let lines = cleaned.components(separatedBy: "\n")
var charCounts: [String: Int] = [:]
let charPattern = try! NSRegularExpression(pattern: #"^([A-Z][A-Z ]+)$"#)
for line in lines {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.count >= 3 && trimmed.count <= 30 {
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if charPattern.firstMatch(in: trimmed, range: range) != nil {
            // Skip common non-character headers
            let skip = ["ACT", "SCENE", "ENTER", "EXIT", "EXEUNT", "ALARUM",
                       "FLOURISH", "THUNDER", "FRONT MATTER", "CONTENTS",
                       "SYNOPSIS", "CHARACTERS IN THE PLAY", "TEXTUAL INTRODUCTION"]
            if !skip.contains(where: { trimmed.hasPrefix($0) }) {
                charCounts[trimmed, default: 0] += 1
            }
        }
    }
}

let sorted = charCounts.sorted { $0.value > $1.value }
print("Characters detected (\(sorted.count)):")
for (name, count) in sorted.prefix(20) {
    print("  \(name): \(count) lines")
}

print("")
print("--- First 2000 chars of cleaned text ---")
print(String(cleaned.prefix(2000)))

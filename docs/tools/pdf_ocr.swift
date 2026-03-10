import AppKit
import Foundation
import PDFKit
import Vision

struct OCRConfig {
    let path: String
    let startPage: Int
    let endPage: Int
    let scale: CGFloat
}

func parseArgs() -> OCRConfig? {
    let args = CommandLine.arguments
    guard args.count >= 4 else {
        fputs("Usage: pdf_ocr.swift <pdf_path> <start_page_1_based> <end_page_1_based> [scale]\n", stderr)
        return nil
    }

    guard let startPage = Int(args[2]), let endPage = Int(args[3]), startPage >= 1, endPage >= startPage else {
        fputs("Invalid page range\n", stderr)
        return nil
    }

    let scale = args.count >= 5 ? (Double(args[4]).flatMap { CGFloat($0) } ?? 2.0) : 2.0
    return OCRConfig(path: args[1], startPage: startPage, endPage: endPage, scale: scale)
}

func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let width = Int(bounds.width * scale)
    let height = Int(bounds.height * scale)
    guard width > 0, height > 0 else { return nil }

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    context.saveGState()
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    page.draw(with: .mediaBox, to: context)
    context.restoreGState()

    return context.makeImage()
}

func recognizeText(from image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])

    let observations = (request.results ?? []).sorted {
        let y0 = $0.boundingBox.minY
        let y1 = $1.boundingBox.minY
        if abs(y0 - y1) > 0.02 {
            return y0 > y1
        }
        return $0.boundingBox.minX < $1.boundingBox.minX
    }

    return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

guard let config = parseArgs() else {
    exit(2)
}

let url = URL(fileURLWithPath: config.path)
guard let document = PDFDocument(url: url) else {
    fputs("Failed to open PDF\n", stderr)
    exit(1)
}

let lowerBound = max(0, config.startPage - 1)
let upperBound = min(document.pageCount - 1, config.endPage - 1)

for pageIndex in lowerBound...upperBound {
    autoreleasepool {
        guard let page = document.page(at: pageIndex) else {
            return
        }
        guard let image = renderPage(page, scale: config.scale) else {
            fputs("Failed to render page \(pageIndex + 1)\n", stderr)
            return
        }

        do {
            let text = try recognizeText(from: image)
            print("=== PAGE \(pageIndex + 1) ===")
            print(text)
        } catch {
            let nsError = error as NSError
            fputs("OCR failed on page \(pageIndex + 1): \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)\n", stderr)
        }
    }
}

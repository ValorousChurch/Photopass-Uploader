#!/usr/bin/env swift

import Foundation
import Vision
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct Config {
    let sourceDirectory: URL
    let unknownFolderName: String
    let recursive: Bool
    let dryRun: Bool
    let verbose: Bool
    let assumeYes: Bool
}

struct PhotoFile {
    let url: URL
    let captureDate: Date?
}

struct QRDetection {
    let payload: String
    let score: Double
}

struct PlannedMove {
    let file: PhotoFile
    let groupName: String
    let qrCode: String?
}

struct RunSummary {
    let detectedQRCount: Int
    let groupCount: Int
    let minPhotosPerGroup: Int
    let maxPhotosPerGroup: Int
    let averagePhotosPerGroup: Double
    let unknownPhotoCount: Int
}

struct GroupWarning {
    let message: String
}

final class ProgressTracker {
    private let total: Int
    private var lastPrintedCount = 0
    private var didRender = false

    init(total: Int) {
        self.total = total
    }

    func advance(to count: Int) {
        guard count != lastPrintedCount else { return }
        lastPrintedCount = count
        let terminator = count == total ? "\n" : ""
        let line = "Scanning \(count) of \(total) photos"
        fputs("\r\(line)", stdout)
        fflush(stdout)
        didRender = true
        if !terminator.isEmpty {
            fputs(terminator, stdout)
        }
    }

    func finishIfNeeded() {
        guard didRender, lastPrintedCount < total else { return }
        advance(to: total)
    }
}

enum PhotoPassError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case sourceNotFound(String)
    case sourceNotDirectory(String)
    case moveFailed(String)
    case cancelled(String)

    var description: String {
        switch self {
        case .invalidArguments(let message),
             .sourceNotFound(let message),
             .sourceNotDirectory(let message),
             .moveFailed(let message),
             .cancelled(let message):
            return message
        }
    }
}

final class QRReader {
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false
    ])

    func decodeQRCode(from fileURL: URL) -> QRDetection? {
        guard let loadedImage = loadImage(from: fileURL) else {
            return nil
        }

        var bestDetection: QRDetection?

        for (index, candidate) in detectionCandidates(for: loadedImage.image).enumerated() {
            if let detection = detectQRCode(in: candidate, orientation: loadedImage.orientation, candidateIndex: index),
               bestDetection.map({ detection.score > $0.score }) ?? true {
                bestDetection = detection
            }
        }

        return bestDetection
    }

    private func loadImage(from fileURL: URL) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationValue = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        return (image, orientation)
    }

    private func detectQRCode(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        candidateIndex: Int
    ) -> QRDetection? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?
            .filter({ $0.payloadStringValue?.isEmpty == false })
            .max(by: { barcodeScore(for: $0, candidateIndex: candidateIndex) < barcodeScore(for: $1, candidateIndex: candidateIndex) })
        else {
            return nil
        }

        guard let payload = observation.payloadStringValue else {
            return nil
        }

        return QRDetection(
            payload: payload,
            score: barcodeScore(for: observation, candidateIndex: candidateIndex)
        )
    }

    private func detectionCandidates(for image: CGImage) -> [CGImage] {
        var candidates: [CGImage] = [image]
        var seen = Set<String>()

        func append(_ candidate: CGImage?) {
            guard let candidate else { return }
            let fingerprint = "\(candidate.width)x\(candidate.height)-\(candidate.bytesPerRow)"
            guard !seen.contains(fingerprint) else { return }
            seen.insert(fingerprint)
            candidates.append(candidate)
        }

        seen.insert("\(image.width)x\(image.height)-\(image.bytesPerRow)")

        for crop in centerCropRects(for: image) {
            append(image.cropping(to: crop))
        }

        append(makeEnhancedImage(from: image, contrast: 1.25, sharpness: 0.4, scale: 1.0))
        append(makeEnhancedImage(from: image, contrast: 1.45, sharpness: 0.7, scale: 1.0))
        append(makeEnhancedImage(from: image, contrast: 1.25, sharpness: 0.4, scale: 1.5))

        for crop in centerCropRects(for: image) {
            guard let cropped = image.cropping(to: crop) else { continue }
            append(makeEnhancedImage(from: cropped, contrast: 1.35, sharpness: 0.6, scale: 1.5))
        }

        return candidates
    }

    private func centerCropRects(for image: CGImage) -> [CGRect] {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let fractions: [CGFloat] = [0.9, 0.75, 0.6]
        let offsets: [(CGFloat, CGFloat)] = [
            (0.0, 0.0),
            (-0.08, 0.0),
            (0.08, 0.0),
            (0.0, -0.08),
            (0.0, 0.08)
        ]

        var rects: [CGRect] = []

        for fraction in fractions {
            let cropWidth = width * fraction
            let cropHeight = height * fraction

            for (xOffsetFactor, yOffsetFactor) in offsets {
                let x = ((width - cropWidth) / 2.0) + (width * xOffsetFactor)
                let y = ((height - cropHeight) / 2.0) + (height * yOffsetFactor)
                let rect = CGRect(
                    x: max(0, min(x, width - cropWidth)),
                    y: max(0, min(y, height - cropHeight)),
                    width: cropWidth,
                    height: cropHeight
                ).integral

                if rect.width > 32, rect.height > 32 {
                    rects.append(rect)
                }
            }
        }

        return rects
    }

    private func makeEnhancedImage(from image: CGImage, contrast: Float, sharpness: Float, scale: CGFloat) -> CGImage? {
        var ciImage = CIImage(cgImage: image)

        let grayscale = CIFilter.colorControls()
        grayscale.inputImage = ciImage
        grayscale.saturation = 0
        grayscale.contrast = contrast
        grayscale.brightness = 0

        guard let grayscaleOutput = grayscale.outputImage else {
            return nil
        }

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = grayscaleOutput
        sharpen.sharpness = sharpness

        guard var output = sharpen.outputImage else {
            return nil
        }

        if scale != 1.0 {
            output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        ciImage = output
        return ciContext.createCGImage(ciImage, from: ciImage.extent.integral)
    }

    private func barcodeScore(for observation: VNBarcodeObservation, candidateIndex: Int) -> Double {
        let area = Double(observation.boundingBox.width * observation.boundingBox.height)
        let confidence = Double(observation.confidence)
        let candidatePenalty = Double(candidateIndex) * 0.01
        return confidence + (area * 0.5) - candidatePenalty
    }
}

func parseArguments() throws -> Config {
    var sourcePath: String?
    var unknownFolderName = "unknown"
    var recursive = false
    var dryRun = false
    var verbose = false
    var assumeYes = false

    var index = 1
    let args = CommandLine.arguments

    while index < args.count {
        let arg = args[index]

        switch arg {
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--recursive", "-r":
            recursive = true
        case "--dry-run":
            dryRun = true
        case "--verbose", "-v":
            verbose = true
        case "--yes", "-y":
            assumeYes = true
        case "--unknown-folder":
            index += 1
            guard index < args.count else {
                throw PhotoPassError.invalidArguments("Missing value for --unknown-folder")
            }
            unknownFolderName = args[index]
        default:
            if arg.hasPrefix("-") {
                throw PhotoPassError.invalidArguments("Unknown option: \(arg)")
            }

            if sourcePath != nil {
                throw PhotoPassError.invalidArguments("Only one source directory may be provided")
            }

            sourcePath = arg
        }

        index += 1
    }

    guard let sourcePath else {
        throw PhotoPassError.invalidArguments("Missing source directory")
    }

    let sourceDirectory = URL(fileURLWithPath: sourcePath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory) else {
        throw PhotoPassError.sourceNotFound("Source directory not found: \(sourceDirectory.path)")
    }

    guard isDirectory.boolValue else {
        throw PhotoPassError.sourceNotDirectory("Source path is not a directory: \(sourceDirectory.path)")
    }

    return Config(
        sourceDirectory: sourceDirectory,
        unknownFolderName: sanitizeFolderName(unknownFolderName),
        recursive: recursive,
        dryRun: dryRun,
        verbose: verbose,
        assumeYes: assumeYes
    )
}

func printUsage() {
    let script = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "photo_pass.swift"
    print(
        """
        Usage:
          swift \(script) /path/to/photo-folder [--recursive] [--dry-run] [--verbose|-v] [--yes|-y] [--unknown-folder NAME]

        Behavior:
          - Scans photos in capture order.
          - When a readable QR is found, that image and all following images go into a folder named after the QR payload.
          - Images before the first readable QR, or images without an active QR group, go into "\(sanitizeFolderName("unknown"))".
          - Unreadable/non-QR images remain with the current active QR group if one exists; otherwise they go into "\(sanitizeFolderName("unknown"))".
          - Summary output is included by default.
          - Non-dry-run mode prints the summary first, then asks for confirmation before moving files.
          - Use --verbose (or -v) to print the per-file move details.
          - Use --yes (or -y) to skip the confirmation prompt and move files immediately after scanning.
        """
    )
}

func supportedPhotoExtensions() -> Set<String> {
    [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"
    ]
}

func collectPhotoFiles(config: Config) throws -> [PhotoFile] {
    let fileManager = FileManager.default
    let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .contentTypeKey,
        .creationDateKey
    ]

    let enumerator: FileManager.DirectoryEnumerator?
    if config.recursive {
        enumerator = fileManager.enumerator(
            at: config.sourceDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: nil
        )
    } else {
        enumerator = fileManager.enumerator(
            at: config.sourceDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: nil
        )
    }

    guard let enumerator else {
        return []
    }

    let extensions = supportedPhotoExtensions()
    var files: [PhotoFile] = []

    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: resourceKeys)
        guard values.isRegularFile == true else { continue }

        let ext = url.pathExtension.lowercased()
        let isSupportedByExtension = extensions.contains(ext)
        let isImageByType = values.contentType?.conforms(to: .image) == true
        guard isSupportedByExtension || isImageByType else { continue }

        let lastComponent = url.lastPathComponent
        if lastComponent == ".DS_Store" { continue }

        let captureDate = readCaptureDate(from: url) ?? values.creationDate
        files.append(PhotoFile(url: url, captureDate: captureDate))
    }

    return files.sorted { lhs, rhs in
        switch (lhs.captureDate, rhs.captureDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }
}

func readCaptureDate(from fileURL: URL) -> Date? {
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
        return nil
    }

    if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
       let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
       let date = parseExifDate(dateString) {
        return date
    }

    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
       let dateString = tiff[kCGImagePropertyTIFFDateTime] as? String,
       let date = parseExifDate(dateString) {
        return date
    }

    return nil
}

func parseExifDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return formatter.date(from: value)
}

func sanitizeFolderName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let invalidScalars = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    let sanitizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
        invalidScalars.contains(scalar) ? "_" : Character(scalar)
    }

    let collapsed = String(sanitizedScalars)
        .replacingOccurrences(of: "\n", with: "_")
        .replacingOccurrences(of: "\r", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: " ."))

    return collapsed.isEmpty ? "unknown" : collapsed
}

func makeUniqueDestination(directory: URL, originalName: String) -> URL {
    let candidate = directory.appendingPathComponent(originalName)
    if !FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }

    let name = (originalName as NSString).deletingPathExtension
    let ext = (originalName as NSString).pathExtension
    var index = 1

    while true {
        let uniqueName = ext.isEmpty ? "\(name)-\(index)" : "\(name)-\(index).\(ext)"
        let uniqueURL = directory.appendingPathComponent(uniqueName)
        if !FileManager.default.fileExists(atPath: uniqueURL.path) {
            return uniqueURL
        }
        index += 1
    }
}

func qrFilename(for code: String, sequence: Int, originalExtension: String) -> String {
    let ext = originalExtension.isEmpty ? "" : ".\(originalExtension)"
    if sequence <= 1 {
        return "_QR-\(code)\(ext)"
    }

    return "_QR-\(code)-\(sequence)\(ext)"
}

func planMoves(config: Config, files: [PhotoFile], reader: QRReader) -> [PlannedMove] {
    let progress = ProgressTracker(total: files.count)
    var detections: [QRDetection?] = []
    detections.reserveCapacity(files.count)

    for (index, file) in files.enumerated() {
        detections.append(reader.decodeQRCode(from: file.url))
        progress.advance(to: index + 1)
    }

    let maxQRBurstLength = 4
    let maxLookbackFrames = 2
    let maxForwardBridgeFrames = 2

    func isLikelySameBurst(_ lhs: PhotoFile, _ rhs: PhotoFile) -> Bool {
        if let leftDate = lhs.captureDate, let rightDate = rhs.captureDate {
            return abs(rightDate.timeIntervalSince(leftDate)) <= 4.0
        }

        return true
    }

    var plannedMoves: [PlannedMove] = []
    var currentGroup = config.unknownFolderName
    var pendingUndecoded: [PhotoFile] = []
    var index = 0

    while index < files.count {
        if let detection = detections[index] {
            var bestDetection = detection
            var runEnd = index
            var absorbedCount = 0
            var compareFile = files[index]

            while absorbedCount < min(maxLookbackFrames, pendingUndecoded.count) {
                let candidateIndex = pendingUndecoded.count - absorbedCount - 1
                let candidate = pendingUndecoded[candidateIndex]
                if !isLikelySameBurst(candidate, compareFile) {
                    break
                }

                absorbedCount += 1
                compareFile = candidate
            }

            let pendingPrefixCount = pendingUndecoded.count - absorbedCount
            if pendingPrefixCount > 0 {
                for pending in pendingUndecoded.prefix(pendingPrefixCount) {
                    plannedMoves.append(PlannedMove(file: pending, groupName: currentGroup, qrCode: nil))
                }
            }

            var qrBurstFiles = Array(pendingUndecoded.suffix(absorbedCount))
            pendingUndecoded.removeAll()
            qrBurstFiles.append(files[index])

            while runEnd + 1 < files.count, qrBurstFiles.count < maxQRBurstLength {
                let nextIndex = runEnd + 1

                if let nextDetection = detections[nextIndex] {
                    if nextDetection.payload != bestDetection.payload {
                        break
                    }

                    if nextDetection.score > bestDetection.score {
                        bestDetection = nextDetection
                    }

                    qrBurstFiles.append(files[nextIndex])
                    runEnd = nextIndex
                    continue
                }

                var bridgeFiles: [PhotoFile] = []
                var bridgeIndex = nextIndex

                while bridgeIndex < files.count,
                      bridgeFiles.count < maxForwardBridgeFrames,
                      qrBurstFiles.count + bridgeFiles.count < maxQRBurstLength,
                      detections[bridgeIndex] == nil,
                      isLikelySameBurst(files[bridgeIndex - 1], files[bridgeIndex]) {
                    bridgeFiles.append(files[bridgeIndex])
                    bridgeIndex += 1
                }

                if !bridgeFiles.isEmpty,
                   bridgeIndex < files.count,
                   let bridgeDetection = detections[bridgeIndex],
                   bridgeDetection.payload == bestDetection.payload,
                   isLikelySameBurst(files[bridgeIndex - 1], files[bridgeIndex]) {
                    if bridgeDetection.score > bestDetection.score {
                        bestDetection = bridgeDetection
                    }

                    qrBurstFiles.append(contentsOf: bridgeFiles)
                    qrBurstFiles.append(files[bridgeIndex])
                    runEnd = bridgeIndex
                    continue
                }

                break
            }

            currentGroup = sanitizeFolderName(bestDetection.payload)

            for burstFile in qrBurstFiles {
                plannedMoves.append(PlannedMove(file: burstFile, groupName: currentGroup, qrCode: currentGroup))
            }

            index = runEnd + 1
            continue
        }

        pendingUndecoded.append(files[index])
        if pendingUndecoded.count > maxLookbackFrames {
            let flushed = pendingUndecoded.removeFirst()
            plannedMoves.append(PlannedMove(file: flushed, groupName: currentGroup, qrCode: nil))
        }
        index += 1
    }

    for pending in pendingUndecoded {
        plannedMoves.append(PlannedMove(file: pending, groupName: currentGroup, qrCode: nil))
    }

    return plannedMoves
}

func summarizeRun(config: Config, plannedMoves: [PlannedMove]) -> RunSummary? {
    let detectedQRCount = plannedMoves.filter { $0.qrCode != nil }.count
    let groupNames = Set(
        plannedMoves
            .filter { $0.groupName != config.unknownFolderName && $0.qrCode != nil }
            .map(\.groupName)
    )

    guard !groupNames.isEmpty else {
        return RunSummary(
            detectedQRCount: detectedQRCount,
            groupCount: 0,
            minPhotosPerGroup: 0,
            maxPhotosPerGroup: 0,
            averagePhotosPerGroup: 0,
            unknownPhotoCount: plannedMoves.filter { $0.groupName == config.unknownFolderName && $0.qrCode == nil }.count
        )
    }

    let photosByGroup = Dictionary(grouping: plannedMoves.filter {
        $0.groupName != config.unknownFolderName && $0.qrCode == nil
    }, by: \.groupName)

    let photoCounts = groupNames.map { photosByGroup[$0]?.count ?? 0 }
    let minPhotos = photoCounts.min() ?? 0
    let maxPhotos = photoCounts.max() ?? 0
    let averagePhotos = Double(photoCounts.reduce(0, +)) / Double(photoCounts.count)

    return RunSummary(
        detectedQRCount: detectedQRCount,
        groupCount: groupNames.count,
        minPhotosPerGroup: minPhotos,
        maxPhotosPerGroup: maxPhotos,
        averagePhotosPerGroup: averagePhotos,
        unknownPhotoCount: plannedMoves.filter { $0.groupName == config.unknownFolderName && $0.qrCode == nil }.count
    )
}

func groupPhotoCounts(config: Config, plannedMoves: [PlannedMove]) -> [String: Int] {
    let groupNames = Set(
        plannedMoves
            .filter { $0.groupName != config.unknownFolderName && $0.qrCode != nil }
            .map(\.groupName)
    )

    let photosByGroup = Dictionary(grouping: plannedMoves.filter {
        $0.groupName != config.unknownFolderName && $0.qrCode == nil
    }, by: \.groupName)

    var counts: [String: Int] = [:]
    for groupName in groupNames {
        counts[groupName] = photosByGroup[groupName]?.count ?? 0
    }
    return counts
}

func buildWarnings(config: Config, plannedMoves: [PlannedMove]) -> [GroupWarning] {
    let counts = groupPhotoCounts(config: config, plannedMoves: plannedMoves)
    guard !counts.isEmpty else { return [] }

    let average = Double(counts.values.reduce(0, +)) / Double(counts.count)
    let largeGroupThreshold = average * 1.5
    var warnings: [GroupWarning] = []

    for groupName in counts.keys.sorted() {
        let count = counts[groupName] ?? 0
        if count == 0 {
            warnings.append(GroupWarning(message: "Warning: group \(groupName) has 0 photos after its QR shots."))
            continue
        }

        if average > 0, Double(count) > largeGroupThreshold {
            warnings.append(
                GroupWarning(
                    message: "Warning: group \(groupName) has \(count) photos, which is more than 1.5x the average (\(formatAverage(average))). The photographer may have missed a new QR card."
                )
            )
        }
    }

    return warnings
}

func formatAverage(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }

    return String(format: "%.1f", value)
}

func printSummary(_ summary: RunSummary, dryRun: Bool) {
    if summary.groupCount == 0 {
        print("Summary:")
        print("  Detected QR codes: \(summary.detectedQRCount)")
        print("  Groups: 0")
        print("  Unknown photos: \(summary.unknownPhotoCount)")
        print("  No photo groups were found.")
        if dryRun {
            print("  Dry run only; no files moved.")
        }
        fflush(stdout)
        return
    }

    print("Summary:")
    print("  Detected QR codes: \(summary.detectedQRCount)")
    print("  Groups: \(summary.groupCount)")
    print("  Group photo counts (min / max / avg): \(summary.minPhotosPerGroup) / \(summary.maxPhotosPerGroup) / \(formatAverage(summary.averagePhotosPerGroup))")
    print("  Unknown photos: \(summary.unknownPhotoCount)")
    if dryRun {
        print("  Dry run only; no files moved.")
    }
    fflush(stdout)
}

func printWarnings(_ warnings: [GroupWarning]) {
    for warning in warnings {
        print(warning.message)
    }
    fflush(stdout)
}

func confirmContinue() -> Bool {
    print("Continue with moving files? [y/N]")
    fflush(stdout)
    guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return false
    }

    return response == "y" || response == "yes"
}

func movePhotos(config: Config, plannedMoves: [PlannedMove]) throws {
    let fileManager = FileManager.default
    var qrSequenceByGroup: [String: Int] = [:]

    for move in plannedMoves {
        let destinationDirectory = config.sourceDirectory.appendingPathComponent(move.groupName, isDirectory: true)
        let originalExtension = move.file.url.pathExtension
        let destinationName: String

        if let qrCode = move.qrCode {
            let nextSequence = (qrSequenceByGroup[move.groupName] ?? 0) + 1
            qrSequenceByGroup[move.groupName] = nextSequence
            destinationName = qrFilename(for: qrCode, sequence: nextSequence, originalExtension: originalExtension)
        } else {
            destinationName = move.file.url.lastPathComponent
        }

        let destinationURL = makeUniqueDestination(
            directory: destinationDirectory,
            originalName: destinationName
        )

        if config.dryRun {
            if config.verbose {
                print("[dry-run] \(move.file.url.lastPathComponent) -> \(move.groupName)/\(destinationURL.lastPathComponent)")
            }
            continue
        }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        do {
            try fileManager.moveItem(at: move.file.url, to: destinationURL)
            if config.verbose {
                print("\(move.file.url.lastPathComponent) -> \(move.groupName)/\(destinationURL.lastPathComponent)")
            }
        } catch {
            throw PhotoPassError.moveFailed(
                "Failed to move \(move.file.url.path) to \(destinationURL.path): \(error.localizedDescription)"
            )
        }
    }
}

do {
    let config = try parseArguments()
    let files = try collectPhotoFiles(config: config)

    if files.isEmpty {
        print("No supported photo files found in \(config.sourceDirectory.path)")
        exit(0)
    }

    let reader = QRReader()
    let plannedMoves = planMoves(config: config, files: files, reader: reader)
    if let summary = summarizeRun(config: config, plannedMoves: plannedMoves) {
        printSummary(summary, dryRun: config.dryRun)
    }

    let warnings = buildWarnings(config: config, plannedMoves: plannedMoves)
    printWarnings(warnings)

    if config.dryRun {
        exit(0)
    }

    if !config.assumeYes && !confirmContinue() {
        throw PhotoPassError.cancelled("Cancelled. No files were moved.")
    }

    try movePhotos(config: config, plannedMoves: plannedMoves)
} catch let error as PhotoPassError {
    switch error {
    case .cancelled(let message):
        print(message)
        exit(0)
    default:
        fputs("Error: \(error.description)\n", stderr)
        printUsage()
        exit(1)
    }
} catch {
    fputs("Unexpected error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

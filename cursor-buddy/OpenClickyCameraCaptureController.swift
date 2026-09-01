//
//  OpenClickyCameraCaptureController.swift
//  cursor-buddy
//
//  Camera device discovery, selection, preview, and still-frame capture for
//  OpenClicky's visual intelligence and meeting-notes workspaces.
//

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreImage
import Foundation

struct OpenClickyCameraDevice: Identifiable, Hashable {
    let id: String
    let localizedName: String
    let manufacturer: String?
    let modelID: String?

    var displayName: String {
        let trimmedManufacturer = manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedManufacturer.isEmpty,
              !localizedName.localizedCaseInsensitiveContains(trimmedManufacturer) else {
            return localizedName
        }
        return "\(localizedName) — \(trimmedManufacturer)"
    }
}

struct OpenClickyCameraFrame: Sendable {
    let data: Data
    let label: String
    let capturedAt: Date
    let width: Int
    let height: Int
}

final class OpenClickyCameraCaptureController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = OpenClickyCameraCaptureController()

    @Published private(set) var availableCameras: [OpenClickyCameraDevice] = []
    @Published var selectedCameraID: String {
        didSet {
            guard oldValue != selectedCameraID else { return }
            UserDefaults.standard.set(selectedCameraID, forKey: AppBundleConfiguration.userCameraDeviceIDDefaultsKey)
            if isRunning {
                restartCaptureSession()
            }
        }
    }
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isRunning = false
    @Published private(set) var latestPreviewImage: NSImage?
    @Published private(set) var latestFrameCapturedAt: Date?
    @Published private(set) var lastErrorMessage: String?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.openclicky.camera.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var latestFrame: OpenClickyCameraFrame?
    private var lastPreviewPublishAt: Date = .distantPast
    private var isConfigured = false

    private override init() {
        self.selectedCameraID = UserDefaults.standard.string(forKey: AppBundleConfiguration.userCameraDeviceIDDefaultsKey) ?? ""
        super.init()
        refreshAvailableCameras()
    }

    var isAuthorized: Bool { authorizationStatus == .authorized }

    var selectedCameraName: String {
        selectedCameraDevice()?.localizedName ?? availableCameras.first?.localizedName ?? "Camera"
    }

    func refreshAvailableCameras() {
        let devices = Self.discoverVideoDevices()
        let mapped = devices.map {
            OpenClickyCameraDevice(
                id: $0.uniqueID,
                localizedName: $0.localizedName,
                manufacturer: $0.manufacturer,
                modelID: $0.modelID
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableCameras = mapped
            if self.selectedCameraID.isEmpty || !mapped.contains(where: { $0.id == self.selectedCameraID }) {
                self.selectedCameraID = mapped.first?.id ?? ""
            }
            self.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    func requestCameraAccessIfNeeded() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        await MainActor.run {
            authorizationStatus = status
        }
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            await MainActor.run {
                authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                if !granted {
                    lastErrorMessage = "Camera permission was not granted."
                }
            }
            return granted
        case .denied, .restricted:
            await MainActor.run {
                lastErrorMessage = "Camera permission is blocked in macOS Privacy settings."
            }
            return false
        @unknown default:
            await MainActor.run {
                lastErrorMessage = "Camera permission is unavailable."
            }
            return false
        }
    }

    func startCaptureSession() {
        Task {
            guard await requestCameraAccessIfNeeded() else { return }
            captureQueue.async { [weak self = self] in
                self?.configureAndStartOnCaptureQueue()
            }
        }
    }

    func stopCaptureSession() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    func restartCaptureSession() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.isConfigured = false
            self.configureAndStartOnCaptureQueue()
        }
    }

    func captureJPEGFrame(labelPrefix: String = "camera") async throws -> OpenClickyCameraFrame {
        if !isRunning {
            startCaptureSession()
        }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let frame = captureQueue.sync(execute: { latestFrame }) {
                let label = "\(labelPrefix): \(selectedCameraName) (image dimensions: \(frame.width)x\(frame.height) pixels)"
                return OpenClickyCameraFrame(
                    data: frame.data,
                    label: label,
                    capturedAt: frame.capturedAt,
                    width: frame.width,
                    height: frame.height
                )
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        throw NSError(
            domain: "OpenClickyCameraCaptureController",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "No camera frame was available yet."]
        )
    }

    private func configureAndStartOnCaptureQueue() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            DispatchQueue.main.async { [weak self] in
                self?.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                self?.lastErrorMessage = "Camera permission is required."
            }
            return
        }

        do {
            if !isConfigured {
                try configureSessionOnCaptureQueue()
            }
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = true
                self?.lastErrorMessage = nil
                self?.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
                self?.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func configureSessionOnCaptureQueue() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        captureSession.sessionPreset = .high

        guard let device = selectedAVCaptureDevice() ?? Self.discoverVideoDevices().first else {
            throw NSError(
                domain: "OpenClickyCameraCaptureController",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No camera is connected."]
            )
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw NSError(
                domain: "OpenClickyCameraCaptureController",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "OpenClicky could not attach the selected camera."]
            )
        }
        captureSession.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            throw NSError(
                domain: "OpenClickyCameraCaptureController",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "OpenClicky could not attach camera frame output."]
            )
        }
        captureSession.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = device.position == .front || device.position == .unspecified
            }
            if #available(macOS 14.0, *) {
                let landscapeRotationAngle: CGFloat = 0
                if connection.isVideoRotationAngleSupported(landscapeRotationAngle) {
                    connection.videoRotationAngle = landscapeRotationAngle
                }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.selectedCameraID = device.uniqueID
        }
        isConfigured = true
    }

    private func selectedCameraDevice() -> OpenClickyCameraDevice? {
        availableCameras.first { $0.id == selectedCameraID }
    }

    private func selectedAVCaptureDevice() -> AVCaptureDevice? {
        let devices = Self.discoverVideoDevices()
        if let selected = devices.first(where: { $0.uniqueID == selectedCameraID }) {
            return selected
        }
        return devices.first
    }

    private static func discoverVideoDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices.sorted { lhs, rhs in
            lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else { return }

        let now = Date()
        let frame = OpenClickyCameraFrame(
            data: jpegData,
            label: "camera",
            capturedAt: now,
            width: cgImage.width,
            height: cgImage.height
        )
        latestFrame = frame

        guard now.timeIntervalSince(lastPreviewPublishAt) >= 0.16 else { return }
        lastPreviewPublishAt = now
        let previewImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        DispatchQueue.main.async { [weak self] in
            self?.latestPreviewImage = previewImage
            self?.latestFrameCapturedAt = now
        }
    }
}

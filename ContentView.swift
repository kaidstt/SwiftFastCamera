//
//  ContentView.swift
//  FastCamera
//
//  Created by Kai Major on 11/04/2026.
//

import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    @State private var camera = CameraModel()
    @State private var pinchStartZoomFactor: CGFloat?

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.clear, .black.opacity(0.18), .black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                statusOverlay
                Spacer()
                lensButtons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(.black)
        .gesture(zoomGesture)
        .task {
            await camera.start()
        }
        .onDisappear {
            Task {
                await camera.stop()
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.authorizationStatus {
        case .denied, .restricted:
            Label("Camera access is required in Settings.", systemImage: "camera.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.clear, in: .capsule)
        case .failed:
            Label("Unable to start the camera session.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
        default:
            EmptyView()
        }
    }

    private var lensButtons: some View {
        HStack(spacing: 18) {
            ForEach(camera.availableLenses) { lens in
                Button {
                    Task {
                        await camera.select(lens)
                    }
                } label: {
                    Text(lens.shortName)
                        .font(camera.selectedLens == lens ? .title3.weight(.semibold) : .callout.weight(.semibold))
                        .foregroundStyle(camera.selectedLens == lens ? .yellow : .white.opacity(0.76))
                        .contentTransition(.numericText())
                        .frame(minWidth: 40)
                }
                .buttonStyle(.plain)
                .scaleEffect(camera.selectedLens == lens ? 1.08 : 1.0)
            }
        }
        .disabled(camera.authorizationStatus != .authorized || camera.availableLenses.isEmpty)
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartZoomFactor == nil {
                    pinchStartZoomFactor = camera.displayZoomFactor
                }

                camera.handlePinchZoom(
                    baseZoomFactor: pinchStartZoomFactor ?? camera.displayZoomFactor,
                    magnification: value.magnification
                )
            }
            .onEnded { _ in
                pinchStartZoomFactor = nil
                camera.finishPinchZoom()
            }
    }
}

@Observable
@MainActor
final class CameraModel {
    enum AuthorizationState {
        case idle
        case authorized
        case denied
        case restricted
        case failed
    }

    struct Lens: Identifiable, Hashable {
        let deviceType: AVCaptureDevice.DeviceType
        let label: String
        let shortName: String
        let actualZoomFactor: CGFloat

        var id: AVCaptureDevice.DeviceType { deviceType }
    }

    var availableLenses: [Lens] = []
    var selectedLens: Lens?
    var authorizationStatus: AuthorizationState = .idle
    var displayZoomFactor: CGFloat = 1.0

    private let preferredBackCameraTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera
    ]
    private let controller = CameraSessionController()

    var session: AVCaptureSession {
        controller.session
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
            await configureAndStartSessionIfNeeded()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                await configureAndStartSessionIfNeeded()
            }
        case .denied:
            authorizationStatus = .denied
        case .restricted:
            authorizationStatus = .restricted
        @unknown default:
            authorizationStatus = .failed
        }
    }

    func stop() async {
        await controller.stopRunning()
    }

    func select(_ lens: Lens) async {
        do {
            let zoomState = try await controller.setZoomFactor(lens.actualZoomFactor, animated: true)
            apply(zoomState)
        } catch {
            authorizationStatus = .failed
        }
    }

    func handlePinchZoom(baseZoomFactor: CGFloat, magnification: CGFloat) {
        let targetZoomFactor = baseZoomFactor * magnification

        Task {
            do {
                let zoomState = try await controller.setDisplayZoomFactor(targetZoomFactor, animated: false)
                apply(zoomState)
            } catch {
                authorizationStatus = .failed
            }
        }
    }

    func finishPinchZoom() {
        // The view owns the gesture baseline; no controller cleanup is needed here.
    }

    private func configureAndStartSessionIfNeeded() async {
        do {
            let configuration = try await controller.configureIfNeeded(preferredDeviceTypes: preferredBackCameraTypes)
            apply(configuration)
            await controller.startRunningIfNeeded()
        } catch {
            authorizationStatus = .failed
        }
    }

    private func apply(_ zoomState: CameraSessionController.ZoomState) {
        availableLenses = zoomState.availableLenses
        selectedLens = zoomState.selectedLens
        displayZoomFactor = zoomState.displayZoomFactor
    }
}

private final class CameraSessionController {
    struct ZoomState {
        let availableLenses: [CameraModel.Lens]
        let selectedLens: CameraModel.Lens
        let displayZoomFactor: CGFloat
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "FastCamera.session")
    private var activeInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var isRunning = false

    func configureIfNeeded(preferredDeviceTypes: [AVCaptureDevice.DeviceType]) async throws -> ZoomState {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    if self.isConfigured {
                        guard let device = self.activeInput?.device else {
                            throw CameraError.missingDevice
                        }
                        let zoomState = try self.currentZoomState(for: device)
                        continuation.resume(returning: zoomState)
                        return
                    }

                    guard let device = self.defaultBackCamera(from: preferredDeviceTypes) else {
                        throw CameraError.missingDevice
                    }

                    let availableLenses = self.makeLenses(for: device)
                    let defaultLens = availableLenses.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? availableLenses.first!

                    self.session.beginConfiguration()
                    self.session.sessionPreset = .high
                    do {
                        try self.addInput(device: device)
                        try self.setZoomFactor(defaultLens.actualZoomFactor, on: device, animated: false)
                        self.session.commitConfiguration()
                    } catch {
                        self.session.commitConfiguration()
                        throw error
                    }

                    self.isConfigured = true
                    continuation.resume(returning: ZoomState(
                        availableLenses: availableLenses,
                        selectedLens: defaultLens,
                        displayZoomFactor: self.displayZoomFactor(for: defaultLens.actualZoomFactor, device: device)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRunningIfNeeded() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                guard self.isConfigured, !self.isRunning else {
                    continuation.resume()
                    return
                }

                self.session.startRunning()
                self.isRunning = self.session.isRunning
                continuation.resume()
            }
        }
    }

    func stopRunning() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                guard self.isRunning else {
                    continuation.resume()
                    return
                }

                self.session.stopRunning()
                self.isRunning = false
                continuation.resume()
            }
        }
    }

    func setZoomFactor(_ actualZoomFactor: CGFloat, animated: Bool) async throws -> ZoomState {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    guard let device = self.activeInput?.device else {
                        throw CameraError.missingDevice
                    }

                    try self.setZoomFactor(actualZoomFactor, on: device, animated: animated)
                    continuation.resume(returning: try self.currentZoomState(for: device, targetActualZoomFactor: actualZoomFactor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setDisplayZoomFactor(_ displayZoomFactor: CGFloat, animated: Bool) async throws -> ZoomState {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    guard let device = self.activeInput?.device else {
                        throw CameraError.missingDevice
                    }

                    let actualZoomFactor = self.actualZoomFactor(for: displayZoomFactor, device: device)
                    try self.setZoomFactor(actualZoomFactor, on: device, animated: animated)
                    continuation.resume(returning: try self.currentZoomState(for: device, targetActualZoomFactor: actualZoomFactor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func addInput(device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }

        session.addInput(input)
        activeInput = input
    }

    private func defaultBackCamera(from deviceTypes: [AVCaptureDevice.DeviceType]) -> AVCaptureDevice? {
        for deviceType in deviceTypes {
            if let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }

    private func makeLenses(for device: AVCaptureDevice) -> [CameraModel.Lens] {
        let multiplier = resolvedDisplayZoomMultiplier(for: device)

        if device.isVirtualDevice {
            let actualZoomFactors = [CGFloat(1)] + device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }

            return zip(device.constituentDevices, actualZoomFactors).map { constituentDevice, actualZoomFactor in
                let displayZoomFactor = displayZoomFactor(for: actualZoomFactor, device: device, multiplier: multiplier)
                return CameraModel.Lens(
                    deviceType: constituentDevice.deviceType,
                    label: label(for: constituentDevice.deviceType),
                    shortName: shortName(for: displayZoomFactor),
                    actualZoomFactor: actualZoomFactor
                )
            }
        }

        return [
            CameraModel.Lens(
                deviceType: device.deviceType,
                label: label(for: device.deviceType),
                shortName: shortName(for: displayZoomFactor(for: 1, device: device, multiplier: multiplier)),
                actualZoomFactor: 1
            )
        ]
    }

    private func currentZoomState(for device: AVCaptureDevice, targetActualZoomFactor: CGFloat? = nil) throws -> ZoomState {
        let availableLenses = makeLenses(for: device)
        guard let selectedLens = selectedLens(for: targetActualZoomFactor ?? device.videoZoomFactor, in: availableLenses) else {
            throw CameraError.missingDevice
        }

        let actualZoomFactor = targetActualZoomFactor ?? device.videoZoomFactor
        return ZoomState(
            availableLenses: availableLenses,
            selectedLens: selectedLens,
            displayZoomFactor: displayZoomFactor(for: actualZoomFactor, device: device)
        )
    }

    private func selectedLens(for actualZoomFactor: CGFloat, in lenses: [CameraModel.Lens]) -> CameraModel.Lens? {
        lenses.last(where: { actualZoomFactor + 0.01 >= $0.actualZoomFactor }) ?? lenses.first
    }

    private func setZoomFactor(_ actualZoomFactor: CGFloat, on device: AVCaptureDevice, animated: Bool) throws {
        let clampedZoomFactor = min(max(actualZoomFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if animated {
            device.ramp(toVideoZoomFactor: clampedZoomFactor, withRate: 32)
        } else {
            if device.isRampingVideoZoom {
                device.cancelVideoZoomRamp()
            }
            device.videoZoomFactor = clampedZoomFactor
        }
    }

    private func displayZoomFactor(for actualZoomFactor: CGFloat, device: AVCaptureDevice, multiplier: CGFloat? = nil) -> CGFloat {
        let resolvedMultiplier = multiplier ?? resolvedDisplayZoomMultiplier(for: device)
        return actualZoomFactor * resolvedMultiplier
    }

    private func actualZoomFactor(for displayZoomFactor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        let multiplier = resolvedDisplayZoomMultiplier(for: device)
        let actualZoomFactor = displayZoomFactor / multiplier
        return min(max(actualZoomFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private func resolvedDisplayZoomMultiplier(for device: AVCaptureDevice) -> CGFloat {
        let multiplier = device.displayVideoZoomFactorMultiplier
        return multiplier > 0 ? multiplier : 1
    }

    private func label(for deviceType: AVCaptureDevice.DeviceType) -> String {
        switch deviceType {
        case .builtInUltraWideCamera:
            "Ultra Wide"
        case .builtInTelephotoCamera:
            "Telephoto"
        default:
            "Wide"
        }
    }

    private func shortName(for displayZoomFactor: CGFloat) -> String {
        let rounded = (displayZoomFactor * 10).rounded() / 10
        if rounded.rounded(.towardZero) == rounded {
            return "\(Int(rounded))x"
        }
        return "\(String(format: "%.1f", rounded))x"
    }

    private enum CameraError: Error {
        case missingDevice
        case cannotAddInput
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.isDeferredStartEnabled = false
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

#Preview {
    CameraView()
}

import SwiftUI

struct ContentView: View {
    var body: some View {
#if os(iOS)
        CameraClassificationView()
#else
        Text("カメラを使った推論はiOSデバイスで実行してください。")
            .padding()
#endif
    }
}

#if os(iOS)
import AVFoundation
import Vision
import Combine

struct CameraClassificationView: View {
    @StateObject private var cameraManager = CameraManager()

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: cameraManager.session)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                if let message = cameraManager.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Text(cameraManager.resultText)
                    .font(.system(.title3, design: .monospaced))
                    .bold()
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.65))
            .cornerRadius(14)
            .padding(24)
        }
        .background(Color.black)
        .onAppear { cameraManager.start() }
        .onDisappear { cameraManager.stop() }
    }
}

final class CameraManager: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case running
        case unauthorized
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.requestingPermission, .requestingPermission), (.running, .running), (.unauthorized, .unauthorized):
                return true
            case (.failed(let l), .failed(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    @Published var resultText: String = "分類中..."
    @Published private(set) var state: State = .idle

    var statusMessage: String? {
        switch state {
        case .requestingPermission:
            return "カメラ利用の許可を確認しています"
        case .unauthorized:
            return "設定からカメラ利用を許可してください"
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    let session = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.otsuridoctor.camera.queue")
    private var lastPredictionDate: Date = .distantPast
    private var classifier: CoinClassifier?
    private var isSessionConfigured = false

    func start() {
        if classifier == nil {
            do {
                classifier = try CoinClassifier()
            } catch {
                state = .failed("モデル読み込みに失敗しました: \(error.localizedDescription)")
                resultText = "モデル読み込みに失敗しました"
                return
            }
        }

        requestPermissionIfNeeded { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                guard granted else {
                    self.state = .unauthorized
                    self.resultText = "カメラアクセスが許可されていません"
                    return
                }
                self.state = .running
                self.configureSessionIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }
    }

    func stop() {
        session.stopRunning()
    }

    private func requestPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default:
            completion(false)
        }
    }

    private func configureSessionIfNeeded() {
        guard !isSessionConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            state = .failed("カメラが利用できません")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            state = .failed("カメラ入力の設定に失敗しました: \(error.localizedDescription)")
            session.commitConfiguration()
            return
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            if #available(iOS 17, *) {
                videoOutput.connection(with: .video)?.videoRotationAngle = 0
            } else {
                videoOutput.connection(with: .video)?.videoOrientation = .portrait
            }
        }

        session.commitConfiguration()
        isSessionConfigured = true
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard state == .running else { return }
        guard Date().timeIntervalSince(lastPredictionDate) >= 1 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let classifier else { return }

        lastPredictionDate = Date()

        do {
            let prediction = try classifier.predict(pixelBuffer: pixelBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.resultText = prediction.lines.joined(separator: "\n")
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.state = .failed("推論に失敗しました")
                self?.resultText = "推論エラー: \(error.localizedDescription)"
            }
        }
    }
}

final class CoinClassifier {
    enum ModelError: LocalizedError {
        case notFound
        case missingOutput

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "CoreMLモデル(.mlmodelまたは.mlmodelc)が見つかりません"
            case .missingOutput:
                return "モデル出力を読み取れませんでした"
            }
        }
    }

    private let model: VNCoreMLModel
    private let labels: [String]
    private let coinValues: [String: Int] = [
        "1yen": 1,
        "5yen": 5,
        "10yen": 10,
        "50yen": 50,
        "100yen": 100,
        "500yen": 500,
        "other": 0
    ]

    init() throws {
        self.labels = Self.loadLabels()
        self.model = try Self.makeModel()
    }

    func predict(pixelBuffer: CVPixelBuffer) throws -> PredictionResult {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var requestError: Error?
        var outputArray: MLMultiArray?

        let request = VNCoreMLRequest(model: model) { request, error in
            if let error {
                requestError = error
                return
            }

            guard
                let observation = request.results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
                let array = observation.featureValue.multiArrayValue
            else {
                requestError = ModelError.missingOutput
                return
            }

            outputArray = array
        }

        request.imageCropAndScaleOption = .centerCrop

        try handler.perform([request])

        if let requestError {
            throw requestError
        }

        guard let outputArray else {
            throw ModelError.missingOutput
        }

        return formatResult(from: outputArray)
    }

    private func formatResult(from array: MLMultiArray) -> PredictionResult {
        var lines: [String] = []
        var totalYen = 0

        let values = (0..<array.count).map { array[$0].doubleValue }
        for (index, value) in values.enumerated() {
            guard index < labels.count else { break }
            let count = Int(round(value))
            let label = labels[index]
            let normalized = label.lowercased().replacingOccurrences(of: " ", with: "")

            if count > 0 && normalized != "other" {
                totalYen += (coinValues[normalized] ?? 0) * count
                lines.append("\(label) \(count)")
            }
        }

        lines.append("合計: \(totalYen)円")
        return PredictionResult(lines: lines, totalYen: totalYen)
    }

    private static func makeModel() throws -> VNCoreMLModel {
        let bundle = Bundle.main

        if let compiledURL = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil)?.first {
            let model = try MLModel(contentsOf: compiledURL)
            return try VNCoreMLModel(for: model)
        }

        if let packageURL = bundle.urls(forResourcesWithExtension: "mlpackage", subdirectory: nil)?.first {
            let model = try MLModel(contentsOf: packageURL)
            return try VNCoreMLModel(for: model)
        }

        if let rawURL = bundle.urls(forResourcesWithExtension: "mlmodel", subdirectory: nil)?.first {
            let compiledURL = try MLModel.compileModel(at: rawURL)
            let model = try MLModel(contentsOf: compiledURL)
            return try VNCoreMLModel(for: model)
        }

        throw ModelError.notFound
    }

    private static func loadLabels() -> [String] {
        guard let url = Bundle.main.url(forResource: "labels", withExtension: "txt") else {
            return [
                "1 yen",
                "5 yen",
                "10 yen",
                "50 yen",
                "100 yen",
                "500 yen",
                "other"
            ]
        }

        if #available(iOS 18, *) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return [
                    "1 yen",
                    "5 yen",
                    "10 yen",
                    "50 yen",
                    "100 yen",
                    "500 yen",
                    "other"
                ]
            }
            let lines = content
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return lines.isEmpty ? [
                "1 yen",
                "5 yen",
                "10 yen",
                "50 yen",
                "100 yen",
                "500 yen",
                "other"
            ] : lines
        } else {
            guard let content = try? String(contentsOf: url) else {
                return [
                    "1 yen",
                    "5 yen",
                    "10 yen",
                    "50 yen",
                    "100 yen",
                    "500 yen",
                    "other"
                ]
            }
            let lines = content
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return lines.isEmpty ? [
                "1 yen",
                "5 yen",
                "10 yen",
                "50 yen",
                "100 yen",
                "500 yen",
                "other"
            ] : lines
        }
    }
}

struct PredictionResult {
    let lines: [String]
    let totalYen: Int
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = self.layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Layer is not AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}
#endif

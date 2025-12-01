import SwiftUI
import CoreData
import Combine
import PhotosUI
import AVFoundation
import Photos
import CoreML

enum EvolutionStage: String {
    case bachelor = "Bachelor"
    case master = "Master"
    case doctor = "Doctor"
    
    static func stage(for count: Int) -> EvolutionStage {
        if count < 2 { return .bachelor }
        if count == 2 { return .master }
        return .doctor
    }
    
    var label: String {
        switch self {
        case .bachelor: return "Bachelor"
        case .master: return "Master"
        case .doctor: return "Doctor"
        }
    }
    
    var imageName: String { rawValue }
}

struct RootView: View {
    @State private var hasStarted = false
    var body: some View {
        Group {
            if hasStarted {
                StartView()
            } else {
                TapToStartView { hasStarted = true }
            }
        }
    }
}

// MARK: - StartView
struct StartView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Item.timestamp, ascending: false)],
        animation: .default)
    private var items: FetchedResults<Item>
    
    @State private var showCamera = false
    @State private var selectedItem: Item?
    @State private var showStats = false
    @State private var isLibraryPickerPresented = false
    @State private var libraryPickerItem: PhotosPickerItem?
    @State private var isLibraryProcessing = false
    @State private var libraryPrediction: PredictionResult?
    @State private var libraryImage: UIImage?
    @State private var showLibraryResult = false
    @State private var showPermissionAlert = false
    @State private var permissionAlertMessage = ""
    @State private var cameraAuthorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photoAuthorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @AppStorage("inferenceCount") private var inferenceCount = 0
    
    private let classifier = CoinClassifier()
    
    private var uniqueDaysCount: Int {
        let calendar = Calendar.current
        let uniqueDays = Set(items.compactMap { item in
            item.timestamp.map { calendar.startOfDay(for: $0) }
        })
        return uniqueDays.count
    }
    private var totalAmount: Int64 {
        items.reduce(0) { $0 + ($1.totalYen) }
    }
    
    // 仮のミッション例（直近3日連続記録？など）
    private var missionText: String {
        uniqueDaysCount >= 3 ? "連続記録3日達成！" : "目指せ連続3日記録！"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GroupBox {
                    VStack(spacing: 8) {
                        Text("記録した日数: \(uniqueDaysCount)日")
                            .font(.title2).bold()
                        Text("累計金額: \(totalAmount)円")
                            .font(.title3)
                        Text(missionText)
                            .font(.headline)
                            .foregroundColor(.orange)
                        if let warning = classifier.loadErrorMessage {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .padding(.bottom, 8)
                
                HStack {
                    Text("記録履歴")
                        .font(.headline)
                    Spacer()
                    Button("グラフ") { showStats = true }
                        .buttonStyle(.bordered)
                }
                if items.isEmpty {
                    Text("まだ記録がありません")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(items) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                HStack {
                                    if let data = item.photo, let uiImage = UIImage(data: data) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 40, height: 40)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        Rectangle()
                                            .fill(Color.secondary)
                                            .frame(width: 40, height: 40)
                                    }
                                    VStack(alignment: .leading) {
                                        Text(item.timestamp ?? Date(), style: .date)
                                            .font(.subheadline)
                                        if let result = item.resultText {
                                            Text(result)
                                                .lineLimit(1)
                                                .font(.caption)
                                        }
                                    }
                                    Spacer()
                                    Text("\(item.totalYen)円")
                                        .bold()
                                }
                            }
                        }
                        .onDelete { indices in
                            for idx in indices {
                                let del = items[idx]
                                viewContext.delete(del)
                            }
                            try? viewContext.save()
                        }
                    }
                    .frame(height: 240)
                }
                Button {
                    requestCameraAccess { granted in
                        if granted {
                            showCamera = true
                        } else {
                            permissionAlertMessage = "カメラへのアクセスを許可してください。\n設定 > プライバシー > カメラ"
                            showPermissionAlert = true
                        }
                    }
                } label: {
                    Text("カメラモードへ")
                        .font(.title2).bold()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .sheet(isPresented: $showCamera) {
                    CameraClassificationView(classifier: classifier)
                        .environment(\.managedObjectContext, viewContext)
                }
                .disabled(!classifier.isReady)
                .padding(.top, 8)
                
                Button {
                    requestPhotoAccess { granted in
                        if granted {
                            isLibraryPickerPresented = true
                        } else {
                            permissionAlertMessage = "フォトライブラリへのアクセスを許可してください。\n設定 > プライバシー > 写真"
                            showPermissionAlert = true
                        }
                    }
                } label: {
                    Text("ライブラリから推論")
                        .font(.title3).bold()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(isLibraryProcessing || !classifier.isReady)
                .padding(.top, 4)
                Spacer()
            }
            .padding()
            .sheet(item: $selectedItem) { item in
                RecordDetailView(item: item)
                    .environment(\.managedObjectContext, viewContext)
            }
            .sheet(isPresented: $showStats) {
                StatsView()
            }
            .sheet(isPresented: $showLibraryResult) {
                LibraryResultView(image: libraryImage, prediction: libraryPrediction) {
                    saveLibraryResult()
                }
            }
            .alert("権限が必要です", isPresented: $showPermissionAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(permissionAlertMessage)
            }
        }
        .onChange(of: libraryPickerItem) { newItem in
            guard let newItem else { return }
            handleLibraryPick(newItem)
        }
        .background(
            Color.clear
                .photosPicker(
                    isPresented: $isLibraryPickerPresented,
                    selection: $libraryPickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                )
        )
    }
    
    private func handleLibraryPick(_ item: PhotosPickerItem) {
        isLibraryProcessing = true
        Task {
            defer { Task { @MainActor in isLibraryProcessing = false } }
            guard classifier.isReady else {
                await MainActor.run {
                    presentLibraryError(classifier.loadErrorMessage ?? "このデバイスでは推論を実行できません。OSをアップデートして再度お試しください。")
                }
                return
            }
            do {
                let image = try await loadImage(from: item)
                guard let image, let buffer = image.pixelBuffer(targetSize: CoinClassifier.targetInputSize) else {
                    await MainActor.run { presentLibraryError("画像の読み込みに失敗しました。別の写真をお試しください。") }
                    return
                }
                let result = try classifier.predict(pixelBuffer: buffer)
                await MainActor.run {
                    libraryImage = image
                    libraryPrediction = result
                    if inferenceCount < 3 { inferenceCount += 1 }
                    showLibraryResult = true
                }
            } catch let error as CoinClassifier.CoinClassifierError {
                await MainActor.run {
                    presentLibraryError(classifierErrorDescription(error))
                }
            } catch {
                await MainActor.run { presentLibraryError("画像の読み込みに失敗しました。別の写真をお試しください。") }
            }
        }
    }

    @MainActor
    private func presentLibraryError(_ message: String) {
        libraryPrediction = PredictionResult(lines: [message], totalYen: 0)
        showLibraryResult = true
    }
    
    private func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraAuthorizationStatus = granted ? .authorized : .denied
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    private func requestPhotoAccess(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    self.photoAuthorizationStatus = newStatus
                    completion(newStatus == .authorized || newStatus == .limited)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    private func saveLibraryResult() {
        guard let pred = libraryPrediction else { return }
        let newItem = Item(context: viewContext)
        newItem.timestamp = Date()
        newItem.resultText = pred.lines.joined(separator: "\n")
        newItem.totalYen = Int64(pred.totalYen)
        newItem.photo = libraryImage?.jpegData(compressionQuality: 0.5)
        try? viewContext.save()
        libraryPrediction = nil
        libraryImage = nil
        showLibraryResult = false
    }
}

// MARK: - Tap to Start
struct TapToStartView: View {
    @AppStorage("inferenceCount") private var inferenceCount = 0
    let onStart: () -> Void
    
    private var evolutionStage: EvolutionStage {
        EvolutionStage.stage(for: min(inferenceCount, 3))
    }
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [.blue.opacity(0.6), .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("おつり博士への道")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                VStack(spacing: 12) {
                    Image(evolutionStage.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(radius: 10)
                    Text("現在のレベル: \(evolutionStage.label)")
                        .font(.title3.bold())
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                Text("Tap to Start")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.2))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                    )
                    .padding(.bottom, 40)
            }
            .padding()
        }
        .onTapGesture { onStart() }
    }
}

// MARK: - CameraClassificationView
struct CameraClassificationView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var cameraManager: CameraManager
    @State private var capturedImage: UIImage?
    @State private var showConfirm = false
    @State private var prediction: PredictionResult?
    @State private var isProcessing = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var classifierError: String?
    @AppStorage("inferenceCount") private var inferenceCount = 0
    @Environment(\.dismiss) private var dismiss
    
    init(classifier: CoinClassifier) {
        _cameraManager = StateObject(wrappedValue: CameraManager(classifier: classifier))
    }
    
    private var evolutionStage: EvolutionStage {
        EvolutionStage.stage(for: min(inferenceCount, 3))
    }
    
    private var displayedInferenceCount: Int { min(inferenceCount, 3) }

    var body: some View {
        ZStack {
            CameraPreview(session: cameraManager.session)
                .ignoresSafeArea()
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("推論で進化中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(evolutionStage.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(radius: 4)
                        Text(evolutionStage.label)
                            .font(.headline)
                        Text("推論回数: \(displayedInferenceCount)/3")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding()
            VStack {
                Spacer()
                if let img = capturedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 250)
                        .background(.black.opacity(0.6))
                        .cornerRadius(16)
                        .shadow(radius: 8)
                        .padding()
                }
                HStack {
                    if capturedImage == nil {
                        Button(action: takePhoto) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 72, height: 72)
                                .overlay(Circle().stroke(Color.gray.opacity(0.6), lineWidth: 2))
                                .shadow(radius: 3)
                                .padding()
                        }
                        .accessibilityLabel("シャッター")
                        .disabled(isProcessing)
                        PhotosPicker(selection: $photoPickerItem, matching: .images, photoLibrary: .shared()) {
                            VStack {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 30, weight: .medium))
                                Text("ライブラリ")
                                    .font(.footnote)
                            }
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(isProcessing)
                    } else {
                        Button("リトライ") {
                            capturedImage = nil
                            prediction = nil
                        }
                        .buttonStyle(.bordered)
                        Button("保存") {
                            saveRecord()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.bottom, 24)
            }
            if isProcessing {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView("解析中...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
            }
            if let error = classifierError {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            if let message = cameraManager.classifier?.loadErrorMessage {
                classifierError = message
            } else {
                cameraManager.start()
            }
        }
        .onDisappear { cameraManager.stop() }
        .onChange(of: photoPickerItem) { newItem in
            guard let newItem else { return }
            loadPhotoFromLibrary(item: newItem)
        }
        .alert("保存完了", isPresented: .constant(prediction != nil && !isProcessing && capturedImage == nil)) {
            Button("OK") { dismiss() }
        }
    }
    
    private func takePhoto() {
        isProcessing = true
        guard let classifier = cameraManager.classifier, classifier.isReady else {
            classifierError = cameraManager.classifier?.loadErrorMessage ?? "このデバイスでは推論を実行できません。OSをアップデートして再度お試しください。"
            isProcessing = false
            return
        }
        cameraManager.capturePhoto { img, pixelBuffer in
            capturedImage = img
            guard let pixelBuffer else {
                isProcessing = false; return
            }
            do {
                let resizedBuffer = img?.pixelBuffer(targetSize: CoinClassifier.targetInputSize) ?? pixelBuffer
                let result = try classifier.predict(pixelBuffer: resizedBuffer)
                prediction = result
                registerInference()
            } catch let error as CoinClassifier.CoinClassifierError {
                classifierError = classifierErrorDescription(error)
                prediction = PredictionResult(lines: [classifierError ?? "解析に失敗しました。"], totalYen: 0)
            } catch {
                prediction = PredictionResult(lines: ["解析失敗: \(error.localizedDescription)"], totalYen: 0)
            }
            isProcessing = false
        }
    }
    
    private func saveRecord() {
        guard let img = capturedImage,
              let pred = prediction else { return }
        let newItem = Item(context: viewContext)
        newItem.timestamp = Date()
        newItem.resultText = pred.lines.joined(separator: "\n")
        newItem.totalYen = Int64(pred.totalYen)
        newItem.photo = img.jpegData(compressionQuality: 0.5)
        try? viewContext.save()
        capturedImage = nil
        prediction = nil
    }
    
    private func registerInference() {
        // 上限3回まででDoctorに到達する想定
        if inferenceCount < 3 { inferenceCount += 1 }
    }
    
    private func loadPhotoFromLibrary(item: PhotosPickerItem) {
        isProcessing = true
        guard let classifier = cameraManager.classifier, classifier.isReady else {
            classifierError = cameraManager.classifier?.loadErrorMessage ?? "このデバイスでは推論を実行できません。OSをアップデートして再度お試しください。"
            isProcessing = false
            return
        }
        Task {
            defer { Task { @MainActor in isProcessing = false } }
            do {
                let image = try await loadImage(from: item)
                guard let image, let buffer = image.pixelBuffer(targetSize: CoinClassifier.targetInputSize) else {
                    await MainActor.run {
                        prediction = PredictionResult(lines: ["画像の読み込みに失敗しました。別の写真をお試しください。"], totalYen: 0)
                    }
                    return
                }
                await MainActor.run {
                    capturedImage = image
                }
                let result = try classifier.predict(pixelBuffer: buffer)
                await MainActor.run {
                    prediction = result
                    registerInference()
                }
            } catch let error as CoinClassifier.CoinClassifierError {
                await MainActor.run {
                    classifierError = classifierErrorDescription(error)
                    prediction = PredictionResult(lines: [classifierError ?? "解析に失敗しました。"], totalYen: 0)
                }
            } catch {
                await MainActor.run {
                    prediction = PredictionResult(lines: ["画像の読み込みに失敗しました。別の写真をお試しください。"], totalYen: 0)
                }
            }
        }
    }
}

// MARK: - RecordDetailView
struct RecordDetailView: View {
    @ObservedObject var item: Item
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @State private var memo: String = ""
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 16) {
            if let data = item.photo, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 180)
                    .cornerRadius(10)
            }
            Text(item.resultText ?? "")
                .font(.body)
                .padding()
                .background(.gray.opacity(0.1))
                .cornerRadius(10)
            Text("合計: \(item.totalYen)円")
                .font(.title2).bold()
            Text(item.timestamp ?? Date(), style: .date)
            TextField("メモ", text: $memo)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存") {
                    item.memo = memo
                    try? viewContext.save()
                    dismiss()
                }
                Button("削除", role: .destructive) {
                    viewContext.delete(item)
                    try? viewContext.save()
                    dismiss()
                }
                Button("シェア") { showShare = true }
            }
        }
        .padding()
        .onAppear { memo = item.memo ?? "" }
        .sheet(isPresented: $showShare) {
            if let data = item.photo, let img = UIImage(data: data) {
                ShareSheet(activityItems: [img, "\(item.resultText ?? "")\n合計: \(item.totalYen)円"])
            } else {
                ShareSheet(activityItems: ["\(item.resultText ?? "")\n合計: \(item.totalYen)円"])
            }
        }
    }
}

// MARK: - グラフ・統計ビュー例
import Charts

struct StatsView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Item.timestamp, ascending: true)],
        animation: .default)
    private var items: FetchedResults<Item>
    
    var dateGroups: [(date: Date, sum: Int64)] {
        let groups = Dictionary(grouping: items) { item in
            Calendar.current.startOfDay(for: item.timestamp ?? Date())
        }
        .mapValues { group in
            group.reduce(0) { $0 + $1.totalYen }
        }
        return groups.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                Text("日別おつり合計グラフ")
                    .font(.headline)
                if dateGroups.isEmpty {
                    Text("データがありません")
                } else {
                    Chart {
                        ForEach(dateGroups, id: \.date) { group in
                            BarMark(
                                x: .value("日付", group.date, unit: .day),
                                y: .value("合計", group.sum)
                            )
                        }
                    }
                    .frame(height: 220)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("グラフ・統計")
        }
    }
}

// MARK: - シェア用View
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - カメラプレビューおよびマネージャー
import AVFoundation
import Vision
import CoreMotion
import CoreImage

struct CameraPreview: UIViewRepresentable {
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
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = self.layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Layer is not AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}

final class CameraManager: NSObject, ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var isSessionConfigured = false
    private let motionManager = CMMotionManager()
    private var latestAttitude: CMAttitude?
    var classifier: CoinClassifier?
    override init() {
        classifier = CoinClassifier()
        super.init()
        startMotionUpdates()
    }
    init(classifier: CoinClassifier) {
        self.classifier = classifier
        super.init()
        startMotionUpdates()
    }
    private func startMotionUpdates() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                if let attitude = motion?.attitude {
                    self?.latestAttitude = attitude
                }
            }
        }
    }
    func start() {
        configureSessionIfNeeded()
        if !session.isRunning { session.startRunning() }
    }
    func stop() {
        session.stopRunning()
        motionManager.stopDeviceMotionUpdates()
    }
    private func configureSessionIfNeeded() {
        guard !isSessionConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration(); return
        }
        session.addInput(input)
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        isSessionConfigured = true
    }
    func capturePhoto(completion: @escaping (UIImage?, CVPixelBuffer?) -> Void) {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: PhotoCaptureProcessor(completion: completion))
    }
}

// MARK: - 写真キャプチャデリゲート
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    let completion: (UIImage?, CVPixelBuffer?) -> Void
    init(completion: @escaping (UIImage?, CVPixelBuffer?) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image: UIImage?
        if let cgImage = photo.cgImageRepresentation() {
            image = UIImage(cgImage: cgImage)
        } else if let data = photo.fileDataRepresentation() {
            image = UIImage(data: data)
        } else {
            image = nil
        }
        let pixelBuffer = photo.pixelBuffer
        completion(image, pixelBuffer)
    }
}

// MARK: - コイン分類器（既存のまま）
final class CoinClassifier {
    enum CoinClassifierError: Error {
        case modelNotLoaded(String)
        case predictionUnavailable
    }
    
    static let targetInputSize = CGSize(width: 512, height: 512)
    // If your count classes are 1..20 instead of 0..19, set this to 1.
    static let countStartOffset = 0
    
    private let vnModel: VNCoreMLModel?
    private let labels: [String]
    private(set) var loadErrorMessage: String?
    var isReady: Bool { vnModel != nil }
    
    init() {
        let bundle = Bundle.main
        var config = MLModelConfiguration()
        // CPUのみ利用して古いOSでのMPSGraph関連クラッシュを回避
        config.computeUnits = .cpuOnly

        guard CoinClassifier.isOSSupported else {
            self.labels = CoinClassifier.loadLabels(from: bundle)
            self.vnModel = nil
            self.loadErrorMessage = "このOSバージョンではモデルが動作しません。iOS 16 または macOS 13 以降でお試しください。"
            return
        }
        
        // ラベル読み込み
        self.labels = CoinClassifier.loadLabels(from: bundle)
        
        // モデル読み込み（mlmodelc優先、次にmlpackageをコンパイル）
        var loadedModel: VNCoreMLModel?
        do {
            if let modelURL = bundle.url(forResource: "coin_model_v2", withExtension: "mlmodelc") {
                let coreMLModel = try MLModel(contentsOf: modelURL, configuration: config)
                loadedModel = try VNCoreMLModel(for: coreMLModel)
            } else if let packageURL = bundle.url(forResource: "coin_model_v2", withExtension: "mlpackage") {
                let compiledURL = try MLModel.compileModel(at: packageURL)
                let coreMLModel = try MLModel(contentsOf: compiledURL, configuration: config)
                loadedModel = try VNCoreMLModel(for: coreMLModel)
            } else {
                loadErrorMessage = "モデルファイルが見つかりません。"
            }
        } catch {
            loadErrorMessage = "モデルの読み込みに失敗しました: \(error.localizedDescription)"
        }
        self.vnModel = loadedModel
        if loadedModel == nil, loadErrorMessage == nil {
            loadErrorMessage = "モデルの読み込みに失敗しました。"
        }
    }
    
    func predict(pixelBuffer: CVPixelBuffer) throws -> PredictionResult {
        guard let vnModel else {
            throw CoinClassifierError.modelNotLoaded(loadErrorMessage ?? "モデルが読み込めませんでした。")
        }
        
        let request = VNCoreMLRequest(model: vnModel)
        request.usesCPUOnly = true // MPSGraphが使えない環境のクラッシュを回避
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        
        // 分類 or MultiArray（カウント）両対応
        if let result = request.results?.first as? VNClassificationObservation {
            let resolvedLabel = resolveLabel(identifier: result.identifier)
            let amount = CoinClassifier.yenAmount(for: resolvedLabel)
            let percent = Int(result.confidence * 100)
            let lines = ["予測: \(resolvedLabel) (\(percent)%)"]
            return PredictionResult(lines: lines, totalYen: amount)
        }
        if let featureObs = request.results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
           let array = featureObs.featureValue.multiArrayValue {
            return predictionFromMultiArray(array)
        }
        throw CoinClassifierError.predictionUnavailable
    }
    
    private func resolveLabel(identifier: String) -> String {
        if labels.contains(identifier) { return identifier }
        // 一致しない場合はidentifierそのまま返す
        return identifier
    }

    private func predictionFromMultiArray(_ array: MLMultiArray) -> PredictionResult {
        var lines: [String] = []
        var totalYen = 0

        // shape: (batch, coinTypes, countClasses) e.g. (1, 6, 20)
        let shape = array.shape.map { $0.intValue }
        if shape.count == 3, shape[0] == 1 {
            let coinTypes = shape[1]
            let countClasses = shape[2]
            let upperCoinIndex = min(coinTypes, labels.count)
            for coinIdx in 0..<upperCoinIndex {
                // 20クラスの確率を取得してワンホット（argmax）に変換
                let probabilities = (0..<countClasses).map { idx in
                    array[[0, coinIdx, idx] as [NSNumber]].doubleValue
                }
                let bestIndex = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) ?? 0
                let oneHot = probabilities.indices.map { $0 == bestIndex ? 1 : 0 }

                let label = labels[coinIdx]
                let predictedCountIndex = oneHot.firstIndex(of: 1) ?? 0
                let predictedCount = predictedCountIndex + CoinClassifier.countStartOffset
                if predictedCount > 0 && label.lowercased() != "other" {
                    totalYen += CoinClassifier.yenAmount(for: label) * predictedCount
                    lines.append("\(label) \(predictedCount)")
                }
            }
            if lines.isEmpty {
                lines.append("予測なし")
            }
            return PredictionResult(lines: lines, totalYen: totalYen)
        }

        let values = (0..<array.count).map { array[$0].doubleValue }
        for (index, value) in values.enumerated() {
            guard index < labels.count else { break }
            let count = Int(round(value))
            let label = labels[index]
            let normalized = label.lowercased().replacingOccurrences(of: " ", with: "")
            if count > 0 && normalized != "other" {
                totalYen += CoinClassifier.yenAmount(for: label) * count
                lines.append("\(label) \(count)")
            }
        }
        if lines.isEmpty {
            lines.append("予測なし")
        }
        return PredictionResult(lines: lines, totalYen: totalYen)
    }

    private static var isOSSupported: Bool {
        #if os(iOS)
        if #available(iOS 16.0, *) { return true }
        #elseif os(macOS)
        if #available(macOS 13.0, *) { return true }
        #endif
        return false
    }

    private static func loadLabels(from bundle: Bundle) -> [String] {
        guard let labelsURL = bundle.url(forResource: "labels", withExtension: "txt"),
              let text = try? String(contentsOf: labelsURL, encoding: .utf8) else {
            return []
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    private static func yenAmount(for label: String) -> Int {
        switch label.lowercased() {
        case "1 yen": return 1
        case "5 yen": return 5
        case "10 yen": return 10
        case "50 yen": return 50
        case "100 yen": return 100
        case "500 yen": return 500
        default: return 0
        }
    }
}
struct PredictionResult {
    let lines: [String]
    let totalYen: Int
}

struct LibraryResultView: View {
    let image: UIImage?
    let prediction: PredictionResult?
    let onSave: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 200)
                        .cornerRadius(12)
                }
                if let prediction {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(prediction.lines, id: \.self) { line in
                            Text(line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("合計: \(prediction.totalYen)円")
                            .font(.title3.bold())
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                } else {
                    Text("結果がありません")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("閉じる") {
                        dismissSheet()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button("保存") {
                        onSave()
                        dismissSheet()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prediction == nil)
                }
                .padding(.top, 8)
                Spacer()
            }
            .padding()
            .navigationTitle("推論結果")
            .toolbar(.hidden, for: .navigationBar)
        }
    }
    
    @Environment(\.dismiss) private var dismiss
    private func dismissSheet() { dismiss() }
}

private func classifierErrorDescription(_ error: CoinClassifier.CoinClassifierError) -> String {
    switch error {
    case .modelNotLoaded(let message):
        return message
    case .predictionUnavailable:
        return "推論を実行できませんでした。別の写真をお試しください。"
    }
}

extension UIImage {
    /// CGImageベースでPixelBufferを生成する簡易ヘルパー
    /// - Parameter targetSize: 指定された場合、そのサイズへリサイズしてからPixelBufferを返す
    func pixelBuffer(targetSize: CGSize? = nil) -> CVPixelBuffer? {
        let cgImage: CGImage?
        if let base = self.cgImage {
            cgImage = base
        } else if let ciImage = self.ciImage {
            let context = CIContext(options: nil)
            cgImage = context.createCGImage(ciImage, from: ciImage.extent)
        } else {
            // UIImage may have only image data; render it into CGImage
            let renderer = UIGraphicsImageRenderer(size: size)
            let rendered = renderer.image { _ in
                self.draw(in: CGRect(origin: .zero, size: size))
            }
            cgImage = rendered.cgImage
        }
        guard let cgImage else { return nil }
        
        let width: Int
        let height: Int
        if let targetSize {
            width = Int(targetSize.width)
            height = Int(targetSize.height)
        } else {
            width = cgImage.width
            height = cgImage.height
        }
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        // リサイズが必要な場合は描画時にサイズを合わせる
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

// MARK: - PhotosPicker 画像読み込みヘルパー
private func loadImage(from item: PhotosPickerItem) async throws -> UIImage? {
    if let data = try await item.loadTransferable(type: Data.self) {
        return UIImage(data: data)
    }
    return nil
}

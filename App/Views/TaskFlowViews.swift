import SwiftUI
import UIKit

struct TaskDetailView: View {
    @EnvironmentObject private var store: AppStore
    var occurrenceId: UUID

    @State private var isSubmittingWithoutPhoto = false
    @State private var showingNoPhotoClaim = false

    private var occurrence: TaskOccurrence? {
        store.occurrences.first { $0.id == occurrenceId }
    }

    var body: some View {
        Group {
            if let occurrence {
                let chore = store.chore(for: occurrence)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        taskHero(chore: chore)

                        if occurrence.status == .missed {
                            Text("You can still submit this chore. Your parent will review it before restoring any deduction.")
                                .font(.subheadline)
                                .foregroundStyle(Color.mutedGray)
                        }

                        VStack(spacing: 12) {
                            detailMetric(title: "Keep", value: "No deduction", color: .acidLime)
                            detailMetric(title: "Miss it", value: Money.dollars(-chore.deductionCents, signed: true), color: .warmOrange)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("What to do")
                                .font(.headline.weight(.heavy))
                            Text(chore.instructions)
                                .font(.body)
                                .foregroundStyle(Color.inkBlack)

                            Divider()

                            Text("Evidence tip")
                                .font(.headline.weight(.heavy))
                            Text(chore.expectedEvidence)
                                .font(.body)
                                .foregroundStyle(Color.mutedGray)
                        }
                        .cardSurface()

                        if store.allowsPhotoEvidence(for: chore) {
                            NavigationLink {
                                CameraCaptureView(occurrenceId: occurrence.id)
                            } label: {
                                Label("Take Photo", systemImage: "camera.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 52)
                                    .foregroundStyle(Color.brandWhite)
                                    .background(Color.brandBlack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(!store.canSubmit(occurrence) || store.isMutationInFlight)
                        }

                        if store.canSubmit(occurrence) {
                            Button("I did it, but don't have a photo") { showingNoPhotoClaim = true }
                                .font(.subheadline.weight(.semibold))
                                .disabled(store.isMutationInFlight)
                                .sheet(isPresented: $showingNoPhotoClaim) { NoPhotoClaimSheet(tasks: [occurrence]) }
                        }

                        if store.allowsNoPhotoSubmission(for: chore) {
                            Button {
                                Task {
                                    await submitWithoutPhoto()
                                }
                            } label: {
                                Label(
                                    occurrence.status == .submitted ? "Submitted" : "Submit Done",
                                    systemImage: occurrence.status == .submitted ? "checkmark.circle.fill" : "checkmark.circle"
                                )
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .foregroundStyle(Color.brandBlack)
                                .background(Color.acidLime, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(isSubmittingWithoutPhoto || !store.canSubmit(occurrence))
                        }

                        Button {
                            Task {
                                await store.requestExcuse(occurrence)
                            }
                        } label: {
                            Text("I can't do this")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(Color.mutedGray)
                        }
                        .disabled(store.isMutationInFlight || !occurrence.status.isOpen)
                        .accessibilityHint("Sends a parent review request")
                    }
                    .padding(22)
                }
                .background(Color.paperWhite.ignoresSafeArea())
                .navigationTitle("Task Detail")
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Task not found", systemImage: "questionmark.circle")
            }
        }
    }

    private func submitWithoutPhoto() async {
        guard !isSubmittingWithoutPhoto else {
            return
        }

        isSubmittingWithoutPhoto = true
        await store.submitWithoutPhoto(for: occurrenceId)
        isSubmittingWithoutPhoto = false
    }

    private func taskHero(chore: ChoreDefinition) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.sunYellow, .sunYellow.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 12) {
                dogIllustration
                    .frame(width: 138, height: 112)

                Text(chore.title)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.brandBlack)

                Text("Every day · Due by \(chore.dueTime)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandBlack.opacity(0.76))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)

            OrangeBlob()
                .fill(Color.warmOrange)
                .frame(width: 70, height: 58)
                .offset(x: 10, y: 12)
        }
        .frame(minHeight: 236)
    }

    private var dogIllustration: some View {
        ZStack {
            Circle()
                .fill(Color.brandWhite)
                .frame(width: 96, height: 86)

            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(red: 0.90, green: 0.68, blue: 0.36))
                .frame(width: 32, height: 68)
                .rotationEffect(.degrees(22))
                .offset(x: -42, y: 2)

            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(red: 0.22, green: 0.14, blue: 0.08))
                .frame(width: 32, height: 68)
                .rotationEffect(.degrees(-22))
                .offset(x: 42, y: 2)

            VStack(spacing: 7) {
                HStack(spacing: 26) {
                    Circle().fill(Color.brandBlack).frame(width: 7, height: 7)
                    Circle().fill(Color.brandBlack).frame(width: 7, height: 7)
                }
                Capsule()
                    .fill(Color.brandBlack)
                    .frame(width: 14, height: 10)
                ArcSmile()
                    .stroke(Color.brandBlack, lineWidth: 2)
                    .frame(width: 28, height: 12)
            }
            .offset(y: 8)
        }
    }

    private func detailMetric(title: String, value: String, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.mutedGray)
                Text(value)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(color)
            }
            Spacer()
        }
        .padding(18)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
    }
}

struct CameraCaptureView: View {
    @EnvironmentObject private var store: AppStore
    var occurrenceId: UUID

    @State private var capturedImage: UIImage?
    @State private var isShowingCamera = false
    @State private var isSubmitting = false
    @State private var isCheckingPhotoPrivacy = false
    @State private var privacyAlert: PhotoPrivacyAlert?
    @State private var showingPhotoConsent = false
    @State private var resumeCaptureAfterConsent = false

    private var occurrence: TaskOccurrence? {
        store.occurrences.first { $0.id == occurrenceId }
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private var blocksPeopleInPhotos: Bool {
        guard let occurrence else {
            return false
        }

        return store.blocksPeopleInEvidence(for: store.chore(for: occurrence))
    }

    var body: some View {
        if let occurrence,
           occurrence.submissionId != nil,
           occurrence.status == .submitted || occurrence.status == .aiReviewed
        {
            AIReviewResultView(occurrenceId: occurrenceId)
        } else {
            cameraSurface
        }
    }

    private var cameraSurface: some View {
        ZStack {
            Color.brandBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                photoSurface
                    .overlay(framingGuides)
                    .overlay {
                        if isSubmitting {
                            ZStack {
                                Color.black.opacity(0.28)
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .tint(Color.brandWhite)
                                        .scaleEffect(1.4)
                                    Text(isCheckingPhotoPrivacy ? "Checking photo privacy..." : "Submitting...")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.brandWhite)
                                }
                            }
                        }
                    }

                VStack(spacing: 20) {
                    HStack {
                        CircleButton(systemImage: "bolt.fill")
                        Spacer()
                        Button {
                            captureTapped()
                        } label: {
                            Circle()
                                .stroke(Color.brandWhite, lineWidth: 4)
                                .frame(width: 78, height: 78)
                                .overlay {
                                    Circle()
                                        .fill(Color.brandWhite)
                                        .frame(width: 62, height: 62)
                                }
                        }
                        .disabled(isSubmitting)
                        .accessibilityLabel("Capture photo")
                        Spacer()
                        CircleButton(systemImage: "arrow.triangle.2.circlepath.camera.fill")
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(Color.sunYellow)
                        Text(
                            blocksPeopleInPhotos
                                ? "Show the task clearly and keep people out of frame."
                                : "Show the full task area clearly."
                        )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brandBlack)
                        Spacer()
                        LimeMascot()
                            .frame(width: 56, height: 60)
                            .clipped()
                    }
                    .padding(16)
                    .background(Color.brandWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(22)
            }
        }
        .navigationTitle("Take a Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.brandBlack, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraImagePicker { image in
                capturedImage = image
                Task {
                    await submitCapturedImage(image)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingPhotoConsent, onDismiss: {
            if resumeCaptureAfterConsent {
                resumeCaptureAfterConsent = false
                captureTapped()
            }
        }) {
            PhotoSharingConsentView(onAccepted: { resumeCaptureAfterConsent = true })
        }
        .alert(item: $privacyAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("Try Again"))
            )
        }
    }

    private var mockPhoto: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.74, green: 0.70, blue: 0.64),
                    Color(red: 0.47, green: 0.42, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 16) {
                ZStack {
                    Ellipse()
                        .fill(Color.brandWhite)
                        .frame(width: 190, height: 74)
                    Ellipse()
                        .fill(Color(red: 0.22, green: 0.13, blue: 0.07))
                        .frame(width: 150, height: 46)
                    HStack(spacing: 6) {
                        ForEach(0..<12, id: \.self) { index in
                            Circle()
                                .fill(Color(red: 0.43, green: 0.24, blue: 0.08))
                                .frame(width: CGFloat(10 + (index % 3) * 3), height: CGFloat(10 + (index % 3) * 3))
                        }
                    }
                    .frame(width: 130)
                }

                HStack(spacing: 22) {
                    ForEach(0..<3, id: \.self) { _ in
                        Image(systemName: "pawprint.fill")
                            .font(.title)
                            .foregroundStyle(Color.brandBlack.opacity(0.75))
                    }
                }
            }
            .offset(y: 70)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 470)
        .clipped()
    }

    @ViewBuilder
    private var photoSurface: some View {
        if let capturedImage {
            Image(uiImage: capturedImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 470)
                .clipped()
        } else {
            mockPhoto
        }
    }

    private func captureTapped() {
        guard !isSubmitting else {
            return
        }

        Task {
            if store.isSignedIn {
                isSubmitting = true
                do {
                    let status = try await store.photoSharingStatus()
                    isSubmitting = false
                    guard status.canUpload else { showingPhotoConsent = true; return }
                } catch {
                    isSubmitting = false
                    privacyAlert = .submissionFailed("Couldn't check photo permission. Please try again.")
                    return
                }
            }
            if cameraAvailable {
                isShowingCamera = true
            } else {
                await submitCapturedImage(nil)
            }
        }
    }

    private func submitCapturedImage(_ image: UIImage?) async {
        isSubmitting = true
        defer {
            isCheckingPhotoPrivacy = false
            isSubmitting = false
        }

        guard let image else {
            let outcome = await store.submitEvidence(for: occurrenceId)
            handleSubmissionOutcome(outcome)
            return
        }

        guard let jpegData = image.evidenceJPEGData() else {
            capturedImage = nil
            privacyAlert = .scanFailed
            return
        }

        if blocksPeopleInPhotos {
            isCheckingPhotoPrivacy = true

            do {
                let containsPerson = try await PhotoPrivacyScanner.containsPerson(in: jpegData)
                guard !containsPerson else {
                    capturedImage = nil
                    privacyAlert = .personDetected
                    return
                }
            } catch {
                capturedImage = nil
                privacyAlert = .scanFailed
                return
            }

            isCheckingPhotoPrivacy = false
        }

        let outcome = await store.submitEvidence(for: occurrenceId, jpegData: jpegData)
        handleSubmissionOutcome(outcome)
    }

    private func handleSubmissionOutcome(_ outcome: EvidenceSubmissionOutcome) {
        guard case let .failed(message) = outcome else {
            return
        }

        capturedImage = nil
        privacyAlert = .submissionFailed(message)
    }

    private var framingGuides: some View {
        GeometryReader { proxy in
            let guideSize: CGFloat = 44
            let lineWidth: CGFloat = 4

            ZStack {
                GuideCorner()
                    .stroke(Color.sunYellow, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .frame(width: guideSize, height: guideSize)
                    .position(x: 48, y: 108)

                GuideCorner()
                    .stroke(Color.sunYellow, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .frame(width: guideSize, height: guideSize)
                    .position(x: proxy.size.width - 48, y: 108)

                GuideCorner()
                    .stroke(Color.sunYellow, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(270))
                    .frame(width: guideSize, height: guideSize)
                    .position(x: 48, y: proxy.size.height - 68)

                GuideCorner()
                    .stroke(Color.sunYellow, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(180))
                    .frame(width: guideSize, height: guideSize)
                    .position(x: proxy.size.width - 48, y: proxy.size.height - 68)
            }
        }
    }
}

private struct PhotoPrivacyAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static let personDetected = PhotoPrivacyAlert(
        title: "Photo not uploaded",
        message: "A person may be visible. This photo stayed on this phone. Try again with everyone out of frame."
    )

    static let scanFailed = PhotoPrivacyAlert(
        title: "Photo check unavailable",
        message: "We could not safely check this photo for people, so it was not uploaded. Please take another photo."
    )

    static func submissionFailed(_ message: String) -> PhotoPrivacyAlert {
        PhotoPrivacyAlert(
            title: "Photo not submitted",
            message: message
        )
    }
}

struct CameraImagePicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraImagePicker

        init(parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private extension UIImage {
    func evidenceJPEGData(maxDimension: CGFloat = 1600, compressionQuality: CGFloat = 0.82) -> Data? {
        let longestSide = max(size.width, size.height)
        let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let normalizedImage = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return normalizedImage.jpegData(compressionQuality: compressionQuality)
    }
}

struct AIReviewResultView: View {
    @EnvironmentObject private var store: AppStore
    var occurrenceId: UUID

    private var occurrence: TaskOccurrence? {
        store.occurrences.first { $0.id == occurrenceId }
    }

    var body: some View {
        let submission = occurrence.flatMap { store.submission(for: $0) }
        let result = submission?.aiResult

        VStack(spacing: 26) {
            Spacer(minLength: 8)

            ZStack {
                LimeMascot()
                FloatingShapes()
            }

            VStack(spacing: 10) {
                Text(reviewTitle(for: result))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(
                    result?.reason ??
                        "Your photo was submitted. The AI check is unavailable, so a parent can review it directly."
                )
                    .font(.body)
                    .foregroundStyle(Color.mutedGray)
                    .multilineTextAlignment(.center)
            }

            if let result {
                let confidence = Int(result.confidence * 100)

                VStack(alignment: .leading, spacing: 12) {
                    Text("AI confidence in this review")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.mutedGray)
                    Text("\(confidence)%")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(reviewTint(for: result))
                    CapsuleProgress(value: result.confidence)
                        .tint(reviewTint(for: result))
                }
                .cardSurface()
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock")
                    .font(.title3.weight(.bold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pending parent review")
                        .font(.headline)
                    Text("AI is advisory. A parent has the final say.")
                        .font(.subheadline)
                        .foregroundStyle(Color.mutedGray)
                }
                Spacer()
            }
            .padding(.horizontal, 6)

            Spacer()

            NavigationLink {
                DashboardView()
            } label: {
                Text("Back to Today")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(Color.brandWhite)
                    .background(Color.brandBlack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .background(Color.paperWhite.ignoresSafeArea())
        .navigationTitle("AI Review")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reviewTitle(for result: AIReviewResult?) -> String {
        guard let result else {
            return "Photo submitted"
        }

        if result.retakeSuggested {
            return "Try another photo"
        }

        switch result.verdict {
        case .likelyComplete:
            return "Likely complete"
        case .likelyIncomplete:
            return "May be incomplete"
        case .needsParentReview:
            return "Needs a parent check"
        }
    }

    private func reviewTint(for result: AIReviewResult) -> Color {
        switch result.verdict {
        case .likelyComplete:
            return .green
        case .likelyIncomplete:
            return .warmOrange
        case .needsParentReview:
            return .warmOrange
        }
    }
}

struct CircleButton: View {
    var systemImage: String

    var body: some View {
        Button {
        } label: {
            Circle()
                .fill(Color.black.opacity(0.42))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(Color.brandWhite)
                }
        }
        .buttonStyle(.plain)
    }
}

struct GuideCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

struct FloatingShapes: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.sunYellow).frame(width: 18, height: 18).offset(x: 100, y: 18)
            BlueTriangle().fill(Color.electricBlue).frame(width: 16, height: 14).offset(x: -96, y: 48)
            BlueTriangle().fill(Color.hotPink).frame(width: 18, height: 16).rotationEffect(.degrees(35)).offset(x: 92, y: -62)
            BlueTriangle().fill(Color.warmOrange).frame(width: 18, height: 16).rotationEffect(.degrees(-24)).offset(x: -84, y: -64)
        }
        .frame(width: 260, height: 200)
        .accessibilityHidden(true)
    }
}

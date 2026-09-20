import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.isParentSession {
                ParentShellView()
            } else {
                ChildShellView()
            }
        }
        .tint(.inkBlack)
        .onOpenURL { url in
            store.handleIncomingURL(url)
        }
        .sheet(item: $store.pendingInvite) { invite in
            InviteLandingSheet(invite: invite)
                .environmentObject(store)
        }
        .alert(item: $store.mutationFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.message),
                dismissButton: .default(Text("Keep Editing"))
            )
        }
        .task {
            await store.loadRemoteFamilyStateIfSignedIn(force: true)
            await store.refreshNotificationScheduleIfAuthorized()
        }
    }
}

struct ChildShellView: View {
    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label("Today", systemImage: "house.fill")
            }

            NavigationStack {
                EarningsView(allowsBonusActions: false)
            }
            .tabItem {
                Label("Earnings", systemImage: "chart.bar.fill")
            }

            NavigationStack {
                WidgetPreviewView()
            }
            .tabItem {
                Label("Widgets", systemImage: "rectangle.grid.2x2.fill")
            }
        }
    }
}

struct ParentShellView: View {
    private enum ParentTab: String {
        case review
        case chores
        case family
        case earnings
        case widgets
    }

    @State private var selectedTab: ParentTab

    init() {
        let launchTab = ProcessInfo.processInfo.environment["CHACHING_START_TAB"]
        _selectedTab = State(initialValue: ParentTab(rawValue: launchTab ?? "") ?? .review)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ParentReviewQueueView()
                    .navigationTitle("Review")
                    .navigationBarTitleDisplayMode(.inline)
                    .parentDebugToolbar()
            }
            .tabItem {
                Label("Review", systemImage: "checklist.checked")
            }
            .tag(ParentTab.review)

            NavigationStack {
                ChoreManagementView()
                    .navigationTitle("Chores")
                    .navigationBarTitleDisplayMode(.inline)
                    .parentDebugToolbar()
            }
            .tabItem {
                Label("Chores", systemImage: "list.bullet.rectangle.fill")
            }
            .tag(ParentTab.chores)

            NavigationStack {
                FamilyManagementView()
                    .navigationTitle("Family")
                    .navigationBarTitleDisplayMode(.inline)
                    .parentDebugToolbar()
            }
            .tabItem {
                Label("Family", systemImage: "person.2.fill")
            }
            .tag(ParentTab.family)

            NavigationStack {
                EarningsView(allowsBonusActions: true)
                    .parentDebugToolbar()
            }
            .tabItem {
                Label("Earnings", systemImage: "chart.bar.fill")
            }
            .tag(ParentTab.earnings)

            NavigationStack {
                WidgetPreviewView()
                    .parentDebugToolbar()
            }
            .tabItem {
                Label("Widgets", systemImage: "rectangle.grid.2x2.fill")
            }
            .tag(ParentTab.widgets)
        }
    }
}

struct DevelopmentSessionMenu: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Menu {
            ForEach(FamilyMemberRole.allCases) { role in
                Button {
                    store.switchSession(to: role)
                } label: {
                    Label(role.title, systemImage: role == .parent ? "person.2.fill" : "face.smiling")
                }
            }
        } label: {
            Image(systemName: store.isParentSession ? "person.2.fill" : "face.smiling")
        }
        .accessibilityLabel("Switch preview role")
    }
}

private extension View {
    @ViewBuilder
    func parentDebugToolbar() -> some View {
        #if DEBUG
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DevelopmentSessionMenu()
            }
            ToolbarItem(placement: .topBarTrailing) {
                RemoteRefreshButton()
            }
        }
        #else
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RemoteRefreshButton()
            }
        }
        #endif
    }
}

struct RemoteRefreshButton: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if store.canAttemptRemoteRefresh {
            Button {
                Task {
                    await store.refreshRemoteFamilyState()
                }
            } label: {
                Image(systemName: store.familySyncState.isWorking ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.headline)
            }
            .disabled(store.familySyncState.isWorking)
            .accessibilityLabel("Refresh family state")
        }
    }
}

struct InviteLandingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    var invite: PendingInvite
    @State private var phoneNumber = ""
    @State private var smsCode = ""
    @State private var hasRequestedCode = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.sunYellow, .acidLime],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(height: 180)

                        MascotCluster(scale: 0.72)
                            .offset(x: 8, y: 12)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("You're invited")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                        Text("Sign in with this phone to join \(store.familyName) as \(invite.kind.roleTitle.lowercased()).")
                            .font(.body)
                            .foregroundStyle(Color.mutedGray)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Phone number", text: $phoneNumber)
                            .focused($isInputFocused)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.roundedBorder)

                        if shouldShowCodeField {
                            TextField("Text code", text: $smsCode)
                                .focused($isInputFocused)
                                .textContentType(.oneTimeCode)
                                .keyboardType(.numberPad)
                                .font(.body.weight(.semibold))
                                .textFieldStyle(.roundedBorder)
                        }

                        if let errorMessage = store.inviteAcceptanceState.errorMessage {
                            Text(errorMessage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.warmOrange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }

                        if let displayName = store.inviteAcceptanceState.acceptedDisplayName {
                            Label("\(displayName) is connected as \(store.inviteAcceptanceState.acceptedRole?.title ?? invite.kind.roleTitle)", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(Color.green)
                        }

                        PrimaryButton(title: primaryButtonTitle, systemImage: primaryButtonIcon) {
                            performPrimaryAction()
                        }
                        .disabled(store.inviteAcceptanceState.isWorking)
                    }

                    #if DEBUG
                    VStack(alignment: .leading, spacing: 8) {
                        Text(invite.token)
                            .font(.caption.monospaced().weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.softGray.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            store.switchSession(to: .child)
                            store.clearPendingInvite()
                            dismiss()
                        } label: {
                            Label("Preview as Child", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.inkBlack)
                        }
                        .buttonStyle(.plain)
                    }
                    #endif
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.paperWhite.ignoresSafeArea())
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isInputFocused = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.clearPendingInvite()
                        dismiss()
                    }
                }
            }
        }
    }

    private var primaryButtonTitle: String {
        switch store.inviteAcceptanceState {
        case .requestingCode:
            return "Sending Code"
        case .codeSent, .failed:
            return shouldShowCodeField ? "Accept Invite" : "Send Code"
        case .accepting:
            return "Accepting"
        case .accepted:
            return "Continue"
        case .idle:
            return "Send Code"
        }
    }

    private var primaryButtonIcon: String {
        switch store.inviteAcceptanceState {
        case .accepted:
            return "arrow.right"
        case .codeSent, .accepting:
            return "checkmark.circle.fill"
        case .idle, .requestingCode, .failed:
            return shouldShowCodeField ? "checkmark.circle.fill" : "message.fill"
        }
    }

    private var shouldShowCodeField: Bool {
        switch store.inviteAcceptanceState {
        case .codeSent, .accepting, .accepted:
            return true
        case .idle, .requestingCode, .failed:
            return hasRequestedCode
        }
    }

    private func performPrimaryAction() {
        isInputFocused = false
        if store.inviteAcceptanceState.acceptedDisplayName != nil {
            store.clearPendingInvite()
            dismiss()
            return
        }

        if hasRequestedCode {
            Task {
                await store.acceptPendingInvite(phoneNumber: phoneNumber, code: smsCode)
            }
        } else {
            Task {
                await store.requestInviteSMSCode(phoneNumber: phoneNumber)
                if case .codeSent = store.inviteAcceptanceState {
                    hasRequestedCode = true
                }
            }
        }
    }
}

private extension PendingInviteKind {
    var roleTitle: String {
        switch self {
        case .child:
            return "Child"
        case .parent:
            return "Parent"
        }
    }
}

import SwiftUI

struct RootView: View {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch app.screen {
            case .home: HomeView().transition(.opacity)
            case .songs: SongPickerView().transition(.move(edge: .trailing))
            case .practice: PracticeView().transition(.move(edge: .trailing))
            case .lesson: LessonView().transition(.move(edge: .trailing))
            case .calibration: CalibrationView(app: app).transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: app.screen)
        .environmentObject(app)
        .preferredColorScheme(.light)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $app.showGrownUps) { GrownUpsView().environmentObject(app) }
        .sheet(isPresented: $app.showCameraPicker) { CameraPickerSheet(hub: app.cameras) }
        .task { await app.bootstrap() }
        .onChange(of: scenePhase) { _, phase in app.cameras.setActive(phase == .active) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            #if targetEnvironment(macCatalyst)
            // On a Mac the window is resizable; keep it big enough for the lesson layout.
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.sizeRestrictions?.minimumSize = CGSize(width: 1100, height: 760)
            }
            #endif
        }
    }
}

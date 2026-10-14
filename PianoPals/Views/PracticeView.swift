import SwiftUI

/// Practice: today's short routine, and every exercise (warm-ups, finger drills, scales, chord climbs) for each hand.
struct PracticeView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        PracticeContent(app: app, model: app)
    }
}

private struct PracticeContent: View {
    let app: AppModel
    @ObservedObject var model: AppModel
    @State private var hand: HandFilter = .both

    enum HandFilter: String, CaseIterable, Identifiable {
        case right = "Right"
        case left = "Left"
        case both = "Both"
        var id: String { rawValue }
        var side: HandSide? { self == .right ? .right : (self == .left ? .left : nil) }
    }

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 20)]

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 20) {
                        BigIconButton(systemImage: "house.fill", label: "Home", color: Palette.pink) { app.screen = .home }
                        Text("Practice").font(.kid(60)).foregroundStyle(Palette.ink)
                        Spacer()
                    }

                    todayCard

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("All exercises").font(.kid(36)).foregroundStyle(Palette.ink)
                            Spacer()
                            Picker("Hand", selection: $hand) {
                                ForEach(HandFilter.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 330)
                            .scaleEffect(1.25)
                            .padding(.trailing, 30)
                        }
                        ForEach(ExerciseCategory.allCases) { category in
                            let items = ExerciseLibrary.exercises(in: category, hand: hand.side, range: app.keyboardRange)
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 10) {
                                        Text(category.emoji).font(.system(size: 36))
                                        Text(category.title).font(.kid(30)).foregroundStyle(Palette.ink)
                                        Text(category.blurb).font(.kid(20, weight: .bold)).foregroundStyle(Palette.ink.opacity(0.6))
                                    }
                                    LazyVGrid(columns: columns, spacing: 20) {
                                        ForEach(items) { exercise in
                                            Button { app.open(exercise.lesson(), returnTo: .practice) } label: { ExerciseCard(exercise: exercise) }
                                                .buttonStyle(BouncyButtonStyle())
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(36)
            }
        }
    }

    private var todayCard: some View {
        let plan = model.dailyPlan
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("⭐ \(plan.title)").font(.kid(40)).foregroundStyle(Palette.ink)
                Text("about \(plan.estimatedMinutes) minutes").font(.kid(24, weight: .bold)).foregroundStyle(Palette.ink.opacity(0.6))
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        VStack(spacing: 6) {
                            Text(step.emoji).font(.system(size: 44))
                            Text(step.title).font(.kid(18, weight: .bold)).foregroundStyle(Palette.ink)
                                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                            HStack(spacing: 4) {
                                Text("\(index + 1)").font(.kid(16)).foregroundStyle(.white)
                                    .frame(width: 26, height: 26).background(Circle().fill(Palette.blueButton))
                                HandBadge(hand: step.lesson.hand)
                            }
                        }
                        .frame(width: 140, height: 140)
                        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.sunny.opacity(0.35)))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1): \(step.title), \(step.lesson.hand.displayName) hand")
                    }
                }
            }
            BigButton(title: "Start practice", systemImage: "play.fill", color: Palette.play, height: 110, fontSize: 40) {
                app.startRoutine(plan)
            }
            .frame(maxWidth: 520)
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 36, style: .continuous).fill(.white).shadow(color: .black.opacity(0.12), radius: 0, y: 8))
    }
}

private struct ExerciseCard: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(exercise.emoji).font(.system(size: 40))
                Spacer()
                HandBadge(hand: exercise.hand, size: 34)
            }
            Text(exercise.title).font(.kid(26)).foregroundStyle(Palette.ink).lineLimit(2).minimumScaleFactor(0.7)
            Text(exercise.subtitle).font(.kid(16, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.6)).lineLimit(2)
            StarRow(filled: exercise.level, total: 3, size: 20)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white).shadow(color: .black.opacity(0.10), radius: 0, y: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(exercise.title), \(exercise.subtitle)")
    }
}

/// A clear "R" / "L" marker for which hand an exercise is for.
struct HandBadge: View {
    let hand: HandSide
    var size: CGFloat = 26

    var body: some View {
        Text(hand == .right ? "R" : "L")
            .font(.kid(size * 0.62))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(hand == .right ? Palette.blueButton : Palette.pink))
            .accessibilityLabel("\(hand.displayName) hand")
    }
}

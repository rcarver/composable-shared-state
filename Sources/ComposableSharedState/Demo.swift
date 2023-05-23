import ComposableArchitecture
import SwiftUI

/// Define a key into the shared value, with a default value.
struct CounterKey: SharedStateKey {
    static var defaultValue: Int = 4
}

struct ParentFeature: ReducerProtocol {
    struct State: Equatable {
        var child1 = ChildFeature.State(name: "A")
        var child2 = ChildFeature.State(name: "B")
        var child3 = ChildFeature.State(name: "C")
        @PresentationState var presentedChild: ChildFeature.State?
        @ParentState<CounterKey> var counter
    }
    enum Action: Equatable {
        case child1(ChildFeature.Action)
        case child2(ChildFeature.Action)
        case child3(ChildFeature.Action)
        case counter(SharedStateAction<CounterKey>)
        case increment
        case presentChildButtonTapped
        case presentedChild(PresentationAction<ChildFeature.Action>)
    }
    init() {}
    var body: some ReducerProtocol<State, Action> {
        WithParentState(\.$counter) {
            Scope(state: \.child1, action: /Action.child1) {
                ChildFeature()
            }
            Scope(state: \.child2, action: /Action.child2) {
                ChildFeature()
            }
            Reduce { state, action in
                switch action {
                case .child1, .child2, .child3:
                    return .none
                case .counter:
                    return .none
                case .increment:
                    state.counter += 1
                    return .none
                case .presentChildButtonTapped:
                    state.presentedChild = ChildFeature.State(name: "P")
                    return .none
                case .presentedChild:
                    return .none
                }
            }
            .sharedState(\.$counter, action: /Action.counter)
            .ifLet(\.$presentedChild, action: /Action.presentedChild) {
                ChildFeature()
            }
        }
        Scope(state: \.child3, action: /Action.child3) {
            ChildFeature()
        }
    }
}

struct ChildFeature: ReducerProtocol {
    struct State: Equatable {
        var localCount: Int = 0
        var name: String
        var sum: Int = 0
        @ChildState<CounterKey> var counter
        init(name: String) {
            self.name = name
        }
    }
    enum Action: Equatable {
        case counter(SharedStateAction<CounterKey>)
        case shareSumButtonTapped
        case sum
        case task
    }
    init() {}
    @Dependency(\.parentState) var parentState
    var body: some ReducerProtocol<State, Action> {
        Reduce { state, action in
            switch action {
            case .counter(.willChange(let newValue)):
                print("ChildFeature.willChange", state.name, state.counter, "=>", newValue)
                return .none
            case .shareSumButtonTapped:
                self.parentState[CounterKey.self] = state.sum
                return .none
            case .sum:
                state.sum = state.localCount + state.counter
                return .none
            case .task:
                state.localCount = .random(in: 1..<100)
                return .none
            }
        }
        .sharedState(\.$counter, action: /Action.counter)
    }
}

struct ParentView: View {
    let store: StoreOf<ParentFeature>
    var body: some View {
        List {
            WithViewStore(store, observe: { $0 }) { viewStore in
                HStack {
                    Button(action: { viewStore.send(.increment) }) {
                        Text("Increment")
                    }
                    Spacer()
                    Text(viewStore.counter.formatted())
                }
            }
            Section {
                ChildView(store: store.scope(state: \.child1, action: ParentFeature.Action.child1))
            }
            Section {
                ChildView(store: store.scope(state: \.child2, action: ParentFeature.Action.child2))
            }
            Section {
                ChildView(store: store.scope(state: \.child3, action: ParentFeature.Action.child3))
            }
        }
        .safeAreaInset(edge: .bottom, content: {
            Button("Present Child") {
                ViewStore(store.stateless).send(.presentChildButtonTapped)
            }
        })
        .sheet(
            store: store.scope(state: \.$presentedChild, action: ParentFeature.Action.presentedChild)
        ) { store in
            List {
                ChildView(store: store)
            }
        }
    }
}

struct ChildView: View {
    let store: StoreOf<ChildFeature>
    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            HStack {
                Text("Local Count")
                Spacer()
                Text(viewStore.localCount.formatted())
            }
            HStack {
                Text("Parent Count")
                Spacer()
                Text(viewStore.counter.formatted())
            }
            HStack {
                Button(action: { viewStore.send(.sum) }) {
                    Text("Update Sum")
                }
                Spacer()
                Text(viewStore.sum.formatted())
            }
            Button("Share Sum to Parent") {
                viewStore.send(.shareSumButtonTapped)
            }
        }
        .task { await ViewStore(store.stateless).send(.task).finish() }
    }
}

struct Parent_Previews: PreviewProvider {
    static var previews: some View {
        ParentView(
            store: Store(
                initialState: ParentFeature.State()
            ) {
                ParentFeature()
            } withDependencies: {
                // Sets a new default value.
                $0.sharedState(CounterKey.self, 100)
            }
        )
    }
}

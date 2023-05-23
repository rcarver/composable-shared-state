import ComposableArchitecture
import SwiftUI

/// Define a key into the shared value, with a default value.
struct CounterKey: ScopedStateKey {
    static var defaultValue: Int = 4
}

struct ParentFeature: ReducerProtocol {
    struct State: Equatable {
        var child1 = ChildFeature.State(name: "A")
        var child2 = ChildFeature.State(name: "B")
        var child3 = ChildFeature.State(name: "C")
        @PresentationState var presentedChild: ChildFeature.State?
        @CreateScopedState<CounterKey> var counter = 10
    }
    enum Action: Equatable {
        case increment
        case child1(ChildFeature.Action)
        case child2(ChildFeature.Action)
        case child3(ChildFeature.Action)
        case presentChildButtonTapped
        case presentedChild(PresentationAction<ChildFeature.Action>)
    }
    init() {}
    var body: some ReducerProtocol<State, Action> {
        WithScopedState(\.$counter) {
            Scope(state: \.child1, action: /Action.child1) {
                ChildFeature()
            }
            Scope(state: \.child2, action: /Action.child2) {
                ChildFeature()
            }
            Reduce { state, action in
                switch action {
                case .increment:
                    state.counter += 1
                    return .none
                case .child1, .child2, .child3:
                    return .none
                case .presentChildButtonTapped:
                    state.presentedChild = ChildFeature.State(name: "P")
                    return .none
                case .presentedChild:
                    return .none
                }
            }
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
        @ScopedState<CounterKey> var sharedCount
        init(name: String) {
            self.name = name
            @ScopedState<CounterKey> var counter
        }
    }
    enum Action: Equatable {
        case sharedCount(ScopedStateAction<CounterKey>)
        case sum
        case task
    }
    @ScopedState<CounterKey> var counter
    init() {}
    var body: some ReducerProtocol<State, Action> {
        Reduce { state, action in
            switch action {
            case .sharedCount(.willChange(let newValue)):
                print("ChildFeature.willChange", state.name, state.sharedCount, "=>", newValue)
                return .none
            case .sum:
                state.sum = state.localCount + state.sharedCount
                return .none
            case .task:
                state.localCount = .random(in: 1..<100)
                return .none
            }
        }
        .observeState(\.$sharedCount, action: /Action.sharedCount)
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
                Text("Shared Count")
                Spacer()
                Text(viewStore.sharedCount.formatted())
            }
            HStack {
                Button(action: { viewStore.send(.sum) }) {
                    Text("Sum Counts")
                }
                Spacer()
                Text(viewStore.sum.formatted())
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
                // This default value will be used where a parent doesn't provide one.
                $0.createScopedState(CounterKey.self, 100)
            }
        )
    }
}

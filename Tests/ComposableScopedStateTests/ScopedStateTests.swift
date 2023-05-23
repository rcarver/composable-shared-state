import XCTest
import ComposableArchitecture
import ComposableScopedState

@MainActor
final class ScopedStateInitTests: XCTestCase {

    struct CounterKey: SharedStateKey {
        static var defaultValue: Int = 1
    }

    struct Child: ReducerProtocol {
        struct State: Equatable {
            @ChildState<CounterKey> var counter
        }
        typealias Action = Never
        var body: some ReducerProtocolOf<Self> { EmptyReducer() }
    }

    func testDefaultValue() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var child = Child.State()
            }
            typealias Action = Never
            var body: some ReducerProtocolOf<Self> { EmptyReducer() }
        }
        let store = TestStore(
            initialState: Parent.State(),
            reducer: Parent()
        )
        XCTAssertEqual(store.state.counter, 1)
        XCTAssertEqual(store.state.child.counter, 1)
    }

    func testWithValue() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter = 2
                var child = Child.State()
            }
            typealias Action = Never
            var body: some ReducerProtocolOf<Self> { EmptyReducer() }
        }
        let store = TestStore(
            initialState: Parent.State(),
            reducer: Parent()
        )
        XCTAssertEqual(store.state.counter, 2)
        XCTAssertEqual(store.state.child.counter, 1)
    }

    func testWithDependencies() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var child = Child.State()
            }
            typealias Action = Never
            var body: some ReducerProtocolOf<Self> { EmptyReducer() }
        }
        let store = TestStore(
            initialState: Parent.State()
        ) {
            Parent()
        } withDependencies: {
            $0.parentState(CounterKey.self, 2)
        }
        XCTAssertEqual(store.state.counter, 2)
        XCTAssertEqual(store.state.child.counter, 2)
    }

    func testWithValueAndWithDependency() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter = 3
                var child = Child.State()
            }
            typealias Action = Never
            var body: some ReducerProtocolOf<Self> { EmptyReducer() }
        }
        let store = TestStore(
            initialState: Parent.State()
        ) {
            Parent()
        } withDependencies: {
            $0.parentState(CounterKey.self, 2)
        }
        XCTAssertEqual(store.state.counter, 3)
        XCTAssertEqual(store.state.child.counter, 2)
    }

    func testInitChildWithValue() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter = 3
                var child = Child.State()
                init() {
                    self.child.counter = self.counter
                }
            }
            typealias Action = Never
            var body: some ReducerProtocolOf<Self> { EmptyReducer() }
        }
        let store = TestStore(
            initialState: Parent.State(),
            reducer: Parent()
        )
        XCTAssertEqual(store.state.counter, 3)
        XCTAssertEqual(store.state.child.counter, 3)
    }
}

@MainActor
final class WithParentStateTests: XCTestCase {

    struct CounterKey: SharedStateKey {
        static var defaultValue: Int = 1
    }

    func testScopedStateObserveState() async throws {
        struct Child: ReducerProtocol {
            struct State: Equatable {
                @ChildState<CounterKey> var counter
                var counterValue: [Int]?
            }
            enum Action: Equatable {
                case counter(ScopedStateAction<CounterKey>)
                case task
            }
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .counter(.willChange(let value)):
                        state.counterValue = [state.counter, value]
                        return .none
                    case .task:
                        return .none
                    }
                }
                .observeParentState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var child1 = Child.State()
                var child2 = Child.State()
            }
            enum Action: Equatable {
                case child1(Child.Action)
                case child2(Child.Action)
                case increment
            }
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .child1, .child2:
                        return .none
                    case .increment:
                        state.counter += 1
                        return .none
                    }
                }
                WithParentState(\.$counter) {
                    Scope(state: \.child1, action: /Action.child1) {
                        Child()
                    }
                }
                Scope(state: \.child2, action: /Action.child2) {
                    Child()
                }
            }
        }
        let store = TestStore(
            initialState: Parent.State(),
            reducer: Parent()
        )
        XCTAssertEqual(store.state.counter, 1)
        XCTAssertEqual(store.state.child1.counter, 1)
        XCTAssertEqual(store.state.child2.counter, 1)
        await store.send(.increment) {
            $0.counter = 2
        }
        let task1 = await store.send(.child1(.task))
        await store.receive(.child1(.counter(.willChange(2)))) {
            $0.child1.counter = 2
            $0.child1.counterValue = [1, 2]
        }
        let task2 = await store.send(.child2(.task))
        await store.send(.increment) {
            $0.counter = 3
        }
        await store.receive(.child1(.counter(.willChange(3)))) {
            $0.child1.counter = 3
            $0.child1.counterValue = [2, 3]
        }
        await task1.cancel()
        await task2.cancel()
    }

    func testScopedStatePresentation() async throws {
        struct Child: ReducerProtocol {
            struct State: Equatable {
                @ChildState<CounterKey> var counter
                var counterValue: [Int]?
            }
            enum Action: Equatable {
                case counter(ScopedStateAction<CounterKey>)
                case task
            }
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .counter(.willChange(let value)):
                        state.counterValue = [state.counter, value]
                        return .none
                    case .task:
                        return .none
                    }
                }
                .observeParentState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                @PresentationState var child: Child.State?
            }
            enum Action: Equatable {
                case child(PresentationAction<Child.Action>)
                case increment
                case presentChild
            }
            var body: some ReducerProtocolOf<Self> {
                WithParentState(\.$counter) {
                    Reduce { state, action in
                        switch action {
                        case .child:
                            return .none
                        case .increment:
                            state.counter += 1
                            return .none
                        case .presentChild:
                            state.child = Child.State()
                            return .none
                        }
                    }
                    .ifLet(\.$child, action: /Action.child) {
                        Child()
                    }
                }
            }
        }
        let store = TestStore(
            initialState: Parent.State(),
            reducer: Parent()
        )
        XCTAssertEqual(store.state.counter, 1)
        await store.send(.increment) {
            $0.counter = 2
        }
        await store.send(.presentChild) {
            $0.child = Child.State()
            $0.child?.counter = 2
        }
        let task = await store.send(.child(.presented(.task)))
        await store.send(.increment) {
            $0.counter = 3
        }
        await store.receive(.child(.presented(.counter(.willChange(3))))) {
            $0.child?.counter = 3
            $0.child?.counterValue = [2, 3]
       }
        await task.cancel()
    }

    func testScopedStateDependencyRead() async throws {
        struct Child: ReducerProtocol {
            struct State: Equatable {
                var counterValue: [Int]?
            }
            enum Action: Equatable {
                case update
            }
            @ChildState<CounterKey> var counter
            @Dependency(\.scopedState) var scopedState
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .update:
                        @ChildState<CounterKey> var counter
                        state.counterValue = [self.counter, self.scopedState[CounterKey.self], counter]
                        return .none
                    }
                }
            }
        }
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var child1 = Child.State()
                var child2 = Child.State()
            }
            enum Action: Equatable {
                case child1(Child.Action)
                case child2(Child.Action)
                case increment
            }
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .child1, .child2:
                        return .none
                    case .increment:
                        state.counter += 1
                        return .none
                    }
                }
                WithParentState(\.$counter) {
                    Scope(state: \.child1, action: /Action.child1) {
                        Child()
                    }
                }
                Scope(state: \.child2, action: /Action.child2) {
                    Child()
                }
            }
        }
        let store = TestStore(
            initialState: Parent.State(),
            reducer: Parent()
        )
        XCTAssertEqual(store.state.counter, 1)
        await store.send(.increment) {
            $0.counter = 2
        }
        await store.send(.child1(.update)) {
            $0.child1.counterValue = [1, 2, 2]
        }
        await store.send(.child2(.update)) {
            $0.child2.counterValue = [1, 1, 1]
        }
    }

    func testScopedStateDependencyWrite() async throws {
        struct Child: ReducerProtocol {
            struct State: Equatable {
                @ChildState<CounterKey> var counter
                var counterValue: Int?
            }
            enum Action: Equatable {
                case counter(ScopedStateAction<CounterKey>)
                case updateParent
                case task
            }
            @Dependency(\.scopedState) var scopedState
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .counter:
                        return .none
                    case .updateParent:
                        self.scopedState[CounterKey.self] = state.counter * 100
                        return .none
                    case .task:
                        return .none
                    }
                }
                .observeParentState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var child1 = Child.State()
                var child2 = Child.State()
            }
            enum Action: Equatable {
                case counter(ScopedStateAction<CounterKey>)
                case child1(Child.Action)
                case child2(Child.Action)
                case increment
            }
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .child1, .child2:
                        return .none
                    case .counter:
                        return .none
                    case .increment:
                        state.counter += 1
                        return .none
                    }
                }
                .observeChildren(\.$counter, action: /Action.counter)
                WithParentState(\.$counter) {
                    Scope(state: \.child1, action: /Action.child1) {
                        Child()
                    }
                }
                Scope(state: \.child2, action: /Action.child2) {
                    Child()
                }
            }
        }
        let store = TestStore(
            initialState: Parent.State(),
            reducer: Parent()
        )
        XCTAssertEqual(store.state.counter, 1)
        let task = await store.send(.increment) {
            $0.counter = 2
        }
        let task1 = await store.send(.child1(.task))
        await store.receive(.child1(.counter(.willChange(2)))) {
            $0.child1.counter = 2
        }
        let task2 = await store.send(.child2(.task))

        await store.send(.child1(.updateParent))
        await store.receive(.counter(.willChange(200))) {
            $0.counter = 200
        }
        await store.receive(.child1(.counter(.willChange(200)))) {
            $0.child1.counter = 200
        }

        XCTExpectFailure()
        await store.send(.child2(.updateParent))

        await task.cancel()
        await task1.cancel()
        await task2.cancel()
    }
}

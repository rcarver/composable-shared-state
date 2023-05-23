import XCTest
import ComposableArchitecture
import ComposableScopedState

@MainActor
final class ScopedStateInitTests: XCTestCase {

    struct CounterKey: ScopedStateKey {
        static var defaultValue: Int = 1
    }

    struct Child: ReducerProtocol {
        struct State: Equatable {
            @ScopedState<CounterKey> var counter
        }
        typealias Action = Never
        var body: some ReducerProtocolOf<Self> { EmptyReducer() }
    }

    func testDefaultValue() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @CreateScopedState<CounterKey> var counter
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
                @CreateScopedState<CounterKey> var counter = 2
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
                @CreateScopedState<CounterKey> var counter
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
            $0.createScopedState(CounterKey.self, 2)
        }
        XCTAssertEqual(store.state.counter, 2)
        XCTAssertEqual(store.state.child.counter, 2)
    }

    func testWithValueAndWithDependency() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @CreateScopedState<CounterKey> var counter = 3
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
            $0.createScopedState(CounterKey.self, 2)
        }
        XCTAssertEqual(store.state.counter, 3)
        XCTAssertEqual(store.state.child.counter, 2)
    }

    func testInitChildWithValue() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @CreateScopedState<CounterKey> var counter = 3
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
final class WithScopedStateTests: XCTestCase {

    struct CounterKey: ScopedStateKey {
        static var defaultValue: Int = 1
    }

    func testObserveState() async throws {
        struct Child: ReducerProtocol {
            struct State: Equatable {
                @ScopedState<CounterKey> var counter
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
                .observeState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @CreateScopedState<CounterKey> var counter
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
                WithScopedState(\.$counter) {
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

    func testPresentation() async throws {
        struct Child: ReducerProtocol {
            struct State: Equatable {
                @ScopedState<CounterKey> var counter
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
                .observeState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @CreateScopedState<CounterKey> var counter
                @PresentationState var child: Child.State?
            }
            enum Action: Equatable {
                case child(PresentationAction<Child.Action>)
                case increment
                case presentChild
            }
            var body: some ReducerProtocolOf<Self> {
                WithScopedState(\.$counter) {
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
}

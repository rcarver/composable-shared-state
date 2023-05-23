import XCTest
import ComposableArchitecture

@testable import ComposableScopedState

@MainActor
final class ScopedStateInitTests: XCTestCase {

    struct CounterKey: ScopedStateKey {
        static var defaultValue: Int = 1
    }

    struct Child: ReducerProtocol {
        struct State: Equatable {
            @ScopedStateValue<CounterKey> var counter
        }
        typealias Action = Never
        var body: some ReducerProtocolOf<Self> { EmptyReducer() }
    }

    func testInitDefaultValue() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ScopedState<CounterKey> var counter
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

    func testInitWithValue() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ScopedState<CounterKey> var counter = 2
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

    func testInitWithDependencies() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ScopedState<CounterKey> var counter
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
            $0.sharedState(CounterKey.self, 2)
        }
        XCTAssertEqual(store.state.counter, 2)
        XCTAssertEqual(store.state.child.counter, 2)
    }

    func testInitWithValueOverridesDepenency() async throws {
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ScopedState<CounterKey> var counter = 3
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
            $0.sharedState(CounterKey.self, 2)
        }
        XCTAssertEqual(store.state.counter, 3)
        XCTAssertEqual(store.state.child.counter, 2)
    }
}

@MainActor
final class WithScopedStateTests: XCTestCase {

    struct CounterKey: ScopedStateKey {
        static var defaultValue: Int = 1
    }

    func testWithScopedValue() async throws {
        struct Child: ReducerProtocol {
            struct State: Equatable {
                @ScopedStateValue<CounterKey> var counter
                var counterValue: Int?
            }
            enum Action {
                case update
            }
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .update:
                        state.counterValue = state.counter
                        return .none
                    }
                }
            }
        }
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ScopedState<CounterKey> var counter
                var child1 = Child.State()
                var child2 = Child.State()
            }
            enum Action {
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
        await store.send(.child1(.update)) {
            $0.child1.counterValue = 2
        }
        await store.send(.child2(.update)) {
            $0.child2.counterValue = 1
        }
    }

    func testObserveState() async throws {
        struct Child: ReducerProtocol {
            struct State: Equatable {
                @ScopedStateValue<CounterKey> var counter
                var counterValue: [Int]?
            }
            enum Action: Equatable {
                case counter(ScopedStateAction<CounterKey>)
                case update
            }
            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .counter(.changed(let value)):
                        state.counterValue = [state.counter, value]
                        return .none
                    case .update:
                        state.counterValue = [state.counter]
                        return .none
                    }
                }
                .observeState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: ReducerProtocol {
            struct State: Equatable {
                @ScopedState<CounterKey> var counter
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
        let task1 = await store.send(.child1(.update)) {
            $0.child1.counterValue = [2]
        }
        let task2 = await store.send(.child2(.update)) {
            $0.child2.counterValue = [1]
        }
        await store.send(.increment) {
            $0.counter = 3
        }
        await store.receive(.child1(.counter(.changed(3)))) {
            $0.child1.counter = 3
            $0.child1.counterValue = [3, 3]
        }
        await task1.cancel()
        await task2.cancel()
    }
}

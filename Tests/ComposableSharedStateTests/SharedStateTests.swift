import XCTest
import ComposableArchitecture
import ComposableSharedState

@MainActor
final class ScopedStateInitTests: XCTestCase {

    struct CounterKey: SharedStateKey {
        static var defaultValue: Int = 1
    }

    struct Child: Reducer {
        struct State: Equatable {
            @ChildState<CounterKey> var counter
        }
        typealias Action = Never
        var body: some ReducerOf<Self> { EmptyReducer() }
    }

    func testDefaultValue() async throws {
        struct Parent: Reducer {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var child = Child.State()
            }
            typealias Action = Never
            var body: some ReducerOf<Self> { EmptyReducer() }
        }
        let store = TestStore(
            initialState: Parent.State(),
            reducer: Parent()
        )
        XCTAssertEqual(store.state.counter, 1)
        XCTAssertEqual(store.state.child.counter, 1)
    }

    func testWithDependencies() async throws {
        struct Parent: Reducer {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var child = Child.State()
            }
            typealias Action = Never
            var body: some ReducerOf<Self> { EmptyReducer() }
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
}

@MainActor
final class WithSharedStateTests: XCTestCase {

    struct CounterKey: SharedStateKey {
        static var defaultValue: Int = 1
    }

    func testChildSharedState() async throws {
        struct Child: Reducer {
            struct State: Equatable {
                @ChildState<CounterKey> var counter
                var counterValue: [Int]?
            }
            enum Action: Equatable {
                case counter(SharedStateAction<CounterKey>)
                case task
            }
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .counter(.willChange(let value)):
                        state.counterValue = [state.counter, value]
                        return .none
                    case .task:
                        return .none
                    }
                }
                .sharedState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: Reducer {
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
            var body: some ReducerOf<Self> {
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

    func testPresentedChildSharedState() async throws {
        struct Child: Reducer {
            struct State: Equatable {
                @ChildState<CounterKey> var counter
                var counterValue: [Int]?
            }
            enum Action: Equatable {
                case counter(SharedStateAction<CounterKey>)
                case task
            }
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .counter(.willChange(let value)):
                        state.counterValue = [state.counter, value]
                        return .none
                    case .task:
                        return .none
                    }
                }
                .sharedState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: Reducer {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                @PresentationState var child: Child.State?
            }
            enum Action: Equatable {
                case child(PresentationAction<Child.Action>)
                case increment
                case presentChild
            }
            var body: some ReducerOf<Self> {
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

    func testParentStateDependencyRead() async throws {
        struct Child: Reducer {
            struct State: Equatable {
                var counterValue: [Int]?
            }
            enum Action: Equatable {
                case update
            }
            @Dependency(\.parentState) var parentState
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .update:
                        @ChildState<CounterKey> var counter
                        state.counterValue = [self.parentState[CounterKey.self], counter]
                        return .none
                    }
                }
            }
        }
        struct Parent: Reducer {
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
            var body: some ReducerOf<Self> {
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
        await store.send(.increment) {
            $0.counter = 2
        }
        await store.send(.child1(.update)) {
            $0.child1.counterValue = [2, 2]
        }
        await store.send(.child2(.update)) {
            $0.child2.counterValue = [1, 1]
        }
    }

    func testParentStateDependencyWrite() async throws {
        struct Child: Reducer {
            struct State: Equatable {
                let value: Int
            }
            enum Action: Equatable {
                case updateParent
            }
            @Dependency(\.parentState) var parentState
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .updateParent:
                        self.parentState[CounterKey.self] = state.value
                        return .none
                    }
                }
            }
        }
        struct Parent: Reducer {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var counterValue: [Int]?
                var child1 = Child.State(value: 100)
                var child2 = Child.State(value: 200)
            }
            enum Action: Equatable {
                case counter(SharedStateAction<CounterKey>)
                case child1(Child.Action)
                case child2(Child.Action)
            }
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .child1, .child2:
                        return .none
                    case .counter(.willChange(let value)):
                        state.counterValue = [state.counter, value]
                        return .none
                    }
                }
                .sharedState(\.$counter, action: /Action.counter)
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
        let task1 = await store.send(.child1(.updateParent))
        await store.receive(.counter(.willChange(100))) {
            $0.counter = 100
            $0.counterValue = [1, 100]
        }

        XCTExpectFailure()
        let task2 = await store.send(.child2(.updateParent))

        await task1.cancel()
        await task2.cancel()
    }

    func testParentStateDependencyRoundTrip() async throws {
        struct Child: Reducer {
            struct State: Equatable {
                @ChildState<CounterKey> var counter
                var counterValue: [Int]?
            }
            enum Action: Equatable {
                case counter(SharedStateAction<CounterKey>)
                case updateParent
                case task
            }
            @Dependency(\.parentState) var parentState
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .counter(.willChange(let value)):
                        state.counterValue = [state.counter, value]
                        return .none
                    case .updateParent:
                        self.parentState[CounterKey.self] = state.counter * 100
                        return .none
                    case .task:
                        return .none
                    }
                }
                .sharedState(\.$counter, action: /Action.counter)
            }
        }
        struct Parent: Reducer {
            struct State: Equatable {
                @ParentState<CounterKey> var counter
                var counterValue: [Int]?
                var child1 = Child.State()
                var child2 = Child.State()
            }
            enum Action: Equatable {
                case counter(SharedStateAction<CounterKey>)
                case child1(Child.Action)
                case child2(Child.Action)
                case increment
                case task
            }
            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .child1, .child2:
                        return .none
                    case .counter(.willChange(let value)):
                        state.counterValue = [state.counter, value]
                        return .none
                    case .increment:
                        state.counter += 1
                        return .none
                    case .task:
                        return .none
                    }
                }
                .sharedState(\.$counter, action: /Action.counter)
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
        let task = await store.send(.task)
        await store.send(.increment) {
            $0.counter = 2
        }
        await store.receive(.counter(.willChange(2))) {
            $0.counterValue = [2, 2]
        }

        let task1 = await store.send(.child1(.task))
        await store.receive(.child1(.counter(.willChange(2)))) {
            $0.child1.counter = 2
            $0.child1.counterValue = [1, 2]
        }
        let task2 = await store.send(.child2(.task))

        func teardown() async {
            await task.cancel()
            await task1.cancel()
            await task2.cancel()
        }

        do {
            try XCTSkipIf(true, "Flakey test due to non-determinitic receive of two async streams on the same value.")

            await store.send(.child1(.updateParent))
            await store.receive(.counter(.willChange(200))) {
                $0.counter = 200
                $0.counterValue = [2, 200]
            }
            await store.receive(.child1(.counter(.willChange(200)))) {
                $0.child1.counter = 200
                $0.child1.counterValue = [2, 200]
            }

            XCTExpectFailure()
            await store.send(.child2(.updateParent))

        } catch {
            await teardown()
            throw error
        }

        await teardown()
    }
}

import Combine
import ComposableArchitecture
import Foundation

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
        @ScopedState<CounterKey> var counter = 10
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
        @ScopedStateValue<CounterKey> var sharedCount
        init(name: String) {
            self.name = name
            @ScopedStateValue<CounterKey> var counter
            print("ChildFeature.init", name, counter, self.sharedCount)
        }
    }
    enum Action: Equatable {
        case sharedCount(ScopedStateAction<CounterKey>)
        case sum
        case task
    }
    @ScopedStateValue<CounterKey> var counter
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
                $0.sharedState(CounterKey.self, 100)
            }
        )
    }
}




///////////////////////////////////////////////


public protocol ScopedStateKey: Sendable, Equatable {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// A property wrapper that can share its value within a defined scope.
@propertyWrapper
public struct ScopedState<Key: ScopedStateKey> where Key.Value: Equatable {
    let id: _ScopeIdentifier
    private var _wrappedValue: Key.Value
    public var projectedValue: Self { self }
    public init(file: StaticString = #fileID, line: UInt = #line) {
        @Dependency(\._scopeId) var scopeId
        @Dependency(\._scopedValues) var values
        self.init(
            wrappedValue: values[Key.self, scope: scopeId],
            file: file,
            line: line
        )
    }
    public init(wrappedValue value: Key.Value, file: StaticString = #fileID, line: UInt = #line) {
        self.id = _ScopeIdentifier(file: file, line: line)
        @Dependency(\._scopedValues) var values
        values[Key.self, scope: self.id] = value
        self._wrappedValue = value
    }
    public var wrappedValue: Key.Value {
        get {
            self._wrappedValue
        }
        set {
            @Dependency(\._scopedValues) var values
            values[Key.self, scope: self.id] = newValue
            self._wrappedValue = newValue
        }
    }
}

extension ScopedState: Equatable where Key.Value: Equatable {}
extension ScopedState: Sendable where Key.Value: Sendable {}

/// A reducer that propagates scoped state to its child reducer.
public struct WithScopedState<Key: ScopedStateKey, ParentState, ParentAction, Child: ReducerProtocol>: ReducerProtocol
where Key.Value: Equatable, ParentState == Child.State, ParentAction == Child.Action
{
    public init(
        _ toScopedState: KeyPath<ParentState, ScopedState<Key>>,
        @ReducerBuilder<Child.State, Child.Action> child: () -> Child
    ) {
        self.toScopedState = toScopedState
        self.child = child()
    }
    private let toScopedState: KeyPath<Child.State, ScopedState<Key>>
    private let child: Child
    public func reduce(into state: inout Child.State, action: Child.Action) -> EffectTask<Child.Action> {
        self.child
            .dependency(\._scopeId, state[keyPath: self.toScopedState].id)
            .reduce(into: &state, action: action)
    }
}

/// A property wrapper that reads a value from scoped state.
///
/// The value is read from the scope when initialized. Any future
/// changes to the value must be updated expliclty using `observeState`.
@propertyWrapper
public struct ScopedStateValue<Key: ScopedStateKey> where Key.Value: Equatable {
    private let id: _ScopeIdentifier
    fileprivate var isObserving: Bool = false
    public var wrappedValue: Key.Value
    public var projectedValue: Self {
        get { self }
        set { self = newValue }
    }
    public init(file: StaticString = #file, line: UInt = #line) {
        self.id = _ScopeIdentifier(file: file, line: line)
        @Dependency(\._scopeId) var scopeId
        @Dependency(\._scopedValues) var sharedValues
        self.wrappedValue = sharedValues[Key.self, scope: scopeId]
    }
}

/// Actions that manage scoped state.
enum ScopedStateAction<Key: ScopedStateKey> {
    case willChange(Key.Value)
}

extension ScopedStateValue: Equatable where Key.Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.wrappedValue == rhs.wrappedValue
    }
}
extension ScopedStateValue: Sendable where Key.Value: Sendable {}

extension ScopedStateAction: Equatable where Key.Value: Equatable {}
extension ScopedStateAction: Sendable where Key.Value: Sendable {}

extension ReducerProtocol {
    /// A higher-order reducer that monitors scoped state for changes and sends an action
    /// back into the system to update local with the current value.
    func observeState<Key: ScopedStateKey>(
        _ toScopedState: WritableKeyPath<State, ScopedStateValue<Key>>,
        action toScopedAction: CasePath<Action, ScopedStateAction<Key>>
    ) -> some ReducerProtocol<State, Action>
    where Key.Value: Equatable
    {
        _ObserveScopedState(
            toScopedState: toScopedState,
            toScopedAction: toScopedAction,
            base: self
        )
    }
}

struct _ObserveScopedState<Key: ScopedStateKey, ParentState, ParentAction, Base: ReducerProtocol>: ReducerProtocol
where Key.Value: Equatable, ParentState == Base.State, ParentAction == Base.Action {
    let toScopedState: WritableKeyPath<ParentState, ScopedStateValue<Key>>
    let toScopedAction: CasePath<ParentAction, ScopedStateAction<Key>>
    let base: Base
    @Dependency(\._scopeId) var scopeId
    @Dependency(\._scopedValues) var sharedValues
    func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<ParentAction> {
        let effects: Effect<Action>
        switch self.toScopedAction.extract(from: action) {
        case .willChange(let value):
            effects = self.base.reduce(into: &state, action: action)
            state[keyPath: toScopedState].wrappedValue = value
        case .none:
            effects = self.base.reduce(into: &state, action: action)
        }
        guard
            !state[keyPath: self.toScopedState].isObserving
        else {
            return effects
        }
        state[keyPath: self.toScopedState].isObserving = true
        let initialValue = state[keyPath: self.toScopedState].wrappedValue
        return .merge(
            effects,
            .run { send in
                for await value in self.sharedValues
                    .observe(Key.self, scope: self.scopeId)
                    .drop(while: { $0 == initialValue })
                {
                    await send(self.toScopedAction.embed(.willChange(value)))
                }
            }
        )
    }
}

extension DependencyValues {
    /// Set the initial value for shared state. This is intended to be used for testing or previews.
    mutating func sharedState<Key: ScopedStateKey>(
        _ key: Key.Type,
        _ value: Key.Value,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let scopeId = _ScopeIdentifier(file: file, line: line)
        self._scopeId = scopeId
        self._scopedValues[Key.self, scope: scopeId] = value
    }
    private struct Identifier: Hashable {
        let file: String
        let line: UInt
    }
}

enum _ScopeIdentifier: Hashable {
    init(file: StaticString = #fileID, line: UInt = #line) {
        self = .static(file: "\(file)", line: line)
    }
    case `default`
    case `static`(file: String, line: UInt)
}

final class _ScopedValues: @unchecked Sendable {
    typealias ValueStorage = [ ObjectIdentifier : Any ]
    typealias ScopeStorage = [ _ScopeIdentifier : ValueStorage ]

    private var storage: CurrentValueSubject<ScopeStorage, Never>

    init(values: ScopeStorage = [:]) {
        self.storage = CurrentValueSubject(values)
    }

    subscript<Key: ScopedStateKey>(_ key: Key.Type, scope scopeId: _ScopeIdentifier) -> Key.Value {
        get {
            guard
                let values = self.storage.value[scopeId],
                let value = values[ObjectIdentifier(key)],
                let value = value as? Key.Value
            else {
                return key.defaultValue
            }
            return value
        }
        set {
            if self.storage.value[scopeId] == nil {
                self.storage.value[scopeId] = [ ObjectIdentifier(key) : newValue ]
            } else {
                self.storage.value[scopeId]![ObjectIdentifier(key)] = newValue
            }
        }
    }
    func observe<Key: ScopedStateKey>(_ key: Key.Type, scope scopeId: _ScopeIdentifier) -> AsyncStream<Key.Value> where Key.Value: Equatable {
        return AsyncStream(
            self.storage
                .compactMap {
                    $0[scopeId]
                }
                .map { values in
                    guard
                        let value = values[ObjectIdentifier(key)],
                        let value = value as? Key.Value
                    else {
                        return key.defaultValue
                    }
                    return value
                }
                .removeDuplicates()
                .values
        )
    }
}

extension _ScopeIdentifier: DependencyKey {
    static let liveValue = Self.default
    static let testValue = Self.default
}

extension DependencyValues {
    var _scopeId: _ScopeIdentifier {
        get { self[_ScopeIdentifier.self] }
        set { self[_ScopeIdentifier.self] = newValue }
    }
}

extension _ScopedValues: DependencyKey {
    static let liveValue = _ScopedValues()
    static let testValue = _ScopedValues()
}

extension DependencyValues {
    var _scopedValues: _ScopedValues {
        get { self[_ScopedValues.self] }
        set { self[_ScopedValues.self] = newValue }
    }
}

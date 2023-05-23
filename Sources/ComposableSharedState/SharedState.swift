import Combine
import ComposableArchitecture
import Foundation

/// A key for sharing state.
///
/// The key defines the type and default value.
public protocol SharedStateKey: Sendable, Equatable {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// A property wrapper that defines the parent for shared state.
@propertyWrapper
public struct ParentState<Key: SharedStateKey> where Key.Value: Equatable {
    fileprivate let scopeId: _ScopeIdentifier
    fileprivate var isObserving: Bool = false
    private var _wrappedValue: Key.Value
    public init(file: StaticString = #fileID, line: UInt = #line) {
        self.scopeId = _ScopeIdentifier(file: file, line: line)
        @Dependency(\._scopeId) var scopeId
        @Dependency(\._scopedValues) var sharedValues
        self._wrappedValue = sharedValues[Key.self, scope: scopeId]
    }
    public var wrappedValue: Key.Value {
        get {
            self._wrappedValue
        }
        set {
            self._wrappedValue = newValue
            @Dependency(\._scopedValues) var values
            values[Key.self, scope: self.scopeId] = newValue
        }
    }
    public var projectedValue: Self {
        get { self }
        set { self = newValue }
    }
}

extension ParentState: Equatable where Key.Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scopeId == rhs.scopeId && lhs._wrappedValue == rhs._wrappedValue
    }
}
extension ParentState: Sendable where Key.Value: Sendable {}

/// A property wrapper that reads shared state from its parent.
@propertyWrapper
public struct ChildState<Key: SharedStateKey> where Key.Value: Equatable {
    fileprivate let scopeId: _ScopeIdentifier
    fileprivate var isObserving: Bool = false
    private var _wrappedValue: Key.Value
    public init(file: StaticString = #fileID, line: UInt = #line) {
        self.scopeId = _ScopeIdentifier(file: file, line: line)
        @Dependency(\._scopeId) var scopeId
        @Dependency(\._scopedValues) var sharedValues
        self._wrappedValue = sharedValues[Key.self, scope: scopeId]
    }
    public var wrappedValue: Key.Value {
        get { self._wrappedValue }
        set { self._wrappedValue = newValue }
    }
    public var projectedValue: Self {
        get { self }
        set { self = newValue }
    }
}

extension ChildState: Equatable where Key.Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scopeId == rhs.scopeId && lhs._wrappedValue == rhs._wrappedValue
    }
}
extension ChildState: Sendable where Key.Value: Sendable {}

/// A reducer that shares parent state its child reducer.
public struct WithParentState<Key: SharedStateKey, ParentReducerState, ParentAction, Child: Reducer>: Reducer
where Key.Value: Equatable, ParentReducerState == Child.State, ParentAction == Child.Action
{
    public init(
        _ toSharedState: KeyPath<ParentReducerState, ParentState<Key>>,
        @ReducerBuilder<Child.State, Child.Action> child: () -> Child
    ) {
        self.toSharedState = toSharedState
        self.child = child()
    }
    private let toSharedState: KeyPath<Child.State, ParentState<Key>>
    private let child: Child
    public func reduce(into state: inout Child.State, action: Child.Action) -> EffectTask<Child.Action> {
        self.child
            .dependency(\._scopeId, state[keyPath: self.toSharedState].scopeId)
            .reduce(into: &state, action: action)
    }
}

/// Actions that manage shared state.
public enum SharedStateAction<Key: SharedStateKey> {
    case willChange(Key.Value)
}

extension SharedStateAction: Equatable where Key.Value: Equatable {}
extension SharedStateAction: Sendable where Key.Value: Sendable {}

extension Reducer {
    /// Enables a `ChildState` to participate in shared state.
    ///
    /// Without applying this modifier, `ChildState` will take its parent
    /// value when initialized but not respond to any future changes.
    public func sharedState<Key: SharedStateKey>(
        _ toSharedState: WritableKeyPath<State, ChildState<Key>>,
        action toSharedAction: CasePath<Action, SharedStateAction<Key>>
    ) -> some Reducer<State, Action>
    where Key.Value: Equatable
    {
        _ObserveSharedState(
            toSharedState: toSharedState,
            toSharedAction: toSharedAction,
            base: self
        ) { _ in
            @Dependency(\._scopeId) var scopeId
            return scopeId
        }
    }
    /// Enables a `ParentState` to participate in shared state.
    ///
    /// Without applying this modifier, `ParentState` is in total
    /// control of the value, it will not accept changes to shared state.
    public func sharedState<Key: SharedStateKey>(
        _ toSharedState: WritableKeyPath<State, ParentState<Key>>,
        action toSharedAction: CasePath<Action, SharedStateAction<Key>>
    ) -> some Reducer<State, Action>
    where Key.Value: Equatable
    {
        _ObserveSharedState(
            toSharedState: toSharedState,
            toSharedAction: toSharedAction,
            base: self
        ) { state in
            state[keyPath: toSharedState].scopeId
        }
    }
}

fileprivate protocol ObservableSharedState {
    associatedtype Value
    var wrappedValue: Value { get set }
    var isObserving: Bool { get set }
}

extension ParentState: ObservableSharedState {}
extension ChildState: ObservableSharedState {}

fileprivate struct _ObserveSharedState<Key: SharedStateKey, Observer: ObservableSharedState, ParentState, ParentAction, Base: Reducer>: Reducer
where Key.Value: Equatable, Observer.Value == Key.Value, ParentState == Base.State, ParentAction == Base.Action {
    let toSharedState: WritableKeyPath<ParentState, Observer>
    let toSharedAction: CasePath<ParentAction, SharedStateAction<Key>>
    let base: Base
    let scopeId: (ParentState) -> _ScopeIdentifier
    @Dependency(\._scopedValues) var sharedValues
    func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<ParentAction> {
        let effects: Effect<Action>
        switch self.toSharedAction.extract(from: action) {
        case .willChange(let value):
            effects = self.base.reduce(into: &state, action: action)
            state[keyPath: toSharedState].wrappedValue = value
        case .none:
            effects = self.base.reduce(into: &state, action: action)
        }
        guard
            !state[keyPath: self.toSharedState].isObserving
        else {
            return effects
        }
        state[keyPath: self.toSharedState].isObserving = true
        let scopeId = self.scopeId(state)
        let initialValue = state[keyPath: self.toSharedState].wrappedValue
        return .merge(
            effects,
            .run { send in
                for await value in self.sharedValues
                    .observe(Key.self, scope: scopeId)
                    .drop(while: { $0 == initialValue })
                {
                    await send(self.toSharedAction.embed(.willChange(value)))
                }
            }
        )
    }
}

/// Read and write parent state.
public final class ParentStateClient: Sendable {
    init() {}
    public subscript<Key: SharedStateKey>(_ key: Key.Type) -> Key.Value {
        get {
            @Dependency(\._scopeId) var scopeId
            @Dependency(\._scopedValues) var sharedValues
            return sharedValues[Key.self, scope: scopeId]
        }
        set {
            @Dependency(\._scopeId) var scopeId
            @Dependency(\._scopedValues) var sharedValues
            sharedValues[Key.self, scope: scopeId] = newValue
        }
    }
}

extension ParentStateClient: DependencyKey {
    public static let testValue = ParentStateClient()
    public static let liveValue = ParentStateClient()
}

extension DependencyValues {
    /// Read and write parent state.
    ///
    /// Changes to a `ParentState` will only have an effect if `observeState`
    /// has been applied to its reducer.
    public var parentState: ParentStateClient {
        self[ParentStateClient.self]
    }
}

extension DependencyValues {
    /// Set a value of shared state in dependencies.
    ///
    /// This creates a new parent scope with default value.
    public mutating func sharedState<Key: SharedStateKey>(
        _ key: Key.Type,
        _ value: Key.Value,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let scopeId = _ScopeIdentifier(file: file, line: line)
        self._scopeId = scopeId
        self._scopedValues[Key.self, scope: scopeId] = value
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
    subscript<Key: SharedStateKey>(_ key: Key.Type, scope scopeId: _ScopeIdentifier) -> Key.Value {
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
            switch scopeId {
            case .default:
                XCTFail("Updating a value in the default scope is not allowed")
            case .static:
                if self.storage.value[scopeId] == nil {
                    self.storage.value[scopeId] = [ ObjectIdentifier(key) : newValue ]
                } else {
                    self.storage.value[scopeId]![ObjectIdentifier(key)] = newValue
                }
            }
        }
    }
    func observe<Key: SharedStateKey>(_ key: Key.Type, scope scopeId: _ScopeIdentifier) -> AsyncStream<Key.Value> where Key.Value: Equatable {
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
        self[_ScopedValues.self]
    }
}

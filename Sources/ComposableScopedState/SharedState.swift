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

/// A property wrapper that defines a new scope for sharing a value with children.
@propertyWrapper
public struct ParentState<Key: SharedStateKey> where Key.Value: Equatable {
    fileprivate let id: _ScopeIdentifier
    fileprivate var isObserving: Bool = false
    private var _wrappedValue: Key.Value
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
            self._wrappedValue = newValue
            @Dependency(\._scopedValues) var values
            values[Key.self, scope: self.id] = newValue
        }
    }
    public var projectedValue: Self {
        get { self }
        set { self = newValue }
    }
}

public typealias ParentStatePropertyWrapper = ParentState

extension ParentState: Equatable where Key.Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs._wrappedValue == rhs._wrappedValue
    }
}
extension ParentState: Sendable where Key.Value: Sendable {}

/// A reducer that propagates a parent's shared state to its child reducer.
public struct WithParentState<Key: SharedStateKey, ParentState, ParentAction, Child: ReducerProtocol>: ReducerProtocol
where Key.Value: Equatable, ParentState == Child.State, ParentAction == Child.Action
{
    public init(
        _ toScopedState: KeyPath<ParentState, ParentStatePropertyWrapper<Key>>,
        @ReducerBuilder<Child.State, Child.Action> child: () -> Child
    ) {
        self.toScopedState = toScopedState
        self.child = child()
    }
    private let toScopedState: KeyPath<Child.State, ParentStatePropertyWrapper<Key>>
    private let child: Child
    public func reduce(into state: inout Child.State, action: Child.Action) -> EffectTask<Child.Action> {
        self.child
            .dependency(\._scopeId, state[keyPath: self.toScopedState].id)
            .reduce(into: &state, action: action)
    }
}

/// A property wrapper that reads from parent state.
///
/// The value is read from the parent when initialized. Any future
/// changes to the value must be updated expliclty using `observeState`.
@propertyWrapper
public struct ChildState<Key: SharedStateKey> where Key.Value: Equatable {
    private let id: _ScopeIdentifier
    fileprivate var isObserving: Bool = false
    private var _wrappedValue: Key.Value
    public init(file: StaticString = #file, line: UInt = #line) {
        self.id = _ScopeIdentifier(file: file, line: line)
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
//            @Dependency(\._scopedValues) var values
//            values[Key.self, scope: self.id] = newValue
        }
    }
    public var projectedValue: Self {
        get { self }
        set { self = newValue }
    }
}

extension ChildState: Equatable where Key.Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs._wrappedValue == rhs._wrappedValue
    }
}
extension ChildState: Sendable where Key.Value: Sendable {}

/// Actions that manage scoped state.
public enum ScopedStateAction<Key: SharedStateKey> {
    case willChange(Key.Value)
}

extension ScopedStateAction: Equatable where Key.Value: Equatable {}
extension ScopedStateAction: Sendable where Key.Value: Sendable {}

extension ReducerProtocol {
    /// A higher-order reducer that monitors scoped state for changes and sends an action
    /// back into the system to synchronize with the current value.
    public func observeParentState<Key: SharedStateKey>(
        _ toScopedState: WritableKeyPath<State, ChildState<Key>>,
        action toScopedAction: CasePath<Action, ScopedStateAction<Key>>
    ) -> some ReducerProtocol<State, Action>
    where Key.Value: Equatable
    {
        _ObserveParentState(
            toScopedState: toScopedState,
            toScopedAction: toScopedAction,
            base: self
        )
    }
}

struct _ObserveParentState<Key: SharedStateKey, ParentState, ParentAction, Base: ReducerProtocol>: ReducerProtocol
where Key.Value: Equatable, ParentState == Base.State, ParentAction == Base.Action {
    let toScopedState: WritableKeyPath<ParentState, ChildState<Key>>
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

extension ReducerProtocol {
    /// A higher-order reducer that monitors a parent state for changes and sends an action
    /// back into the system to synchronize with the current value.
    public func observeChildren<Key: SharedStateKey>(
        _ toScopedState: WritableKeyPath<State, ParentState<Key>>,
        action toScopedAction: CasePath<Action, ScopedStateAction<Key>>
    ) -> some ReducerProtocol<State, Action>
    where Key.Value: Equatable
    {
        _ObserveChildrenState(
            toScopedState: toScopedState,
            toScopedAction: toScopedAction,
            base: self
        )
    }
}

struct _ObserveChildrenState<Key: SharedStateKey, ParentState, ParentAction, Base: ReducerProtocol>: ReducerProtocol
where Key.Value: Equatable, ParentState == Base.State, ParentAction == Base.Action {
    let toScopedState: WritableKeyPath<ParentState, ParentStatePropertyWrapper<Key>>
    let toScopedAction: CasePath<ParentAction, ScopedStateAction<Key>>
    let base: Base
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
        let scopeId = state[keyPath: self.toScopedState].id
        let initialValue = state[keyPath: self.toScopedState].wrappedValue
        return .merge(
            effects,
            .run { send in
                for await value in self.sharedValues
                    .observe(Key.self, scope: scopeId)
                    .drop(while: { $0 == initialValue })
                {
                    await send(self.toScopedAction.embed(.willChange(value)))
                }
            }
        )
    }
}

extension DependencyValues {
    /// Create a parent state in dependencies instead of state.
    ///
    /// This is intended to be used for testing or previews where no parent
    /// feature provides a scope via `@ParentState`.
    public mutating func parentState<Key: SharedStateKey>(
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
            if self.storage.value[scopeId] == nil {
                self.storage.value[scopeId] = [ ObjectIdentifier(key) : newValue ]
            } else {
                self.storage.value[scopeId]![ObjectIdentifier(key)] = newValue
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

public final class ScopedStateClient: Sendable {
    init() {}
    public subscript<Key: SharedStateKey>(_ key: Key.Type) -> Key.Value {
        get {
            @Dependency(\._scopeId) var scopeId
            @Dependency(\._scopedValues) var sharedValues
            return sharedValues[Key.self, scope: scopeId]
        }
        set {
            @Dependency(\._scopeId) var scopeId
            switch scopeId {
            case .default:
                XCTFail("Updating a value in the default scope is not allowed")
            case .static:
                @Dependency(\._scopedValues) var sharedValues
                sharedValues[Key.self, scope: scopeId] = newValue
            }
        }
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

extension ScopedStateClient: DependencyKey {
    public static let testValue = ScopedStateClient()
    public static let liveValue = ScopedStateClient()
}

extension DependencyValues {
    /// Access scoped state as a dependency.
    ///
    /// This may be preferable when the value is only needed inside a reducer.
    public var scopedState: ScopedStateClient {
        self[ScopedStateClient.self]
    }
}

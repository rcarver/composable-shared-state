import Combine
import ComposableArchitecture
import Foundation

public protocol ScopedStateKey: Sendable, Equatable {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// A property wrapper that can share its value within a defined scope.
@propertyWrapper
public struct CreateScopedState<Key: ScopedStateKey> where Key.Value: Equatable {
    fileprivate let id: _ScopeIdentifier
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
            self._wrappedValue = newValue
            @Dependency(\._scopedValues) var values
            values[Key.self, scope: self.id] = newValue
        }
    }
}

extension CreateScopedState: Equatable where Key.Value: Equatable {}
extension CreateScopedState: Sendable where Key.Value: Sendable {}

/// A reducer that propagates a created scope to its child reducer.
public struct WithScopedState<Key: ScopedStateKey, ParentState, ParentAction, Child: ReducerProtocol>: ReducerProtocol
where Key.Value: Equatable, ParentState == Child.State, ParentAction == Child.Action
{
    public init(
        _ toScopedState: KeyPath<ParentState, CreateScopedState<Key>>,
        @ReducerBuilder<Child.State, Child.Action> child: () -> Child
    ) {
        self.toScopedState = toScopedState
        self.child = child()
    }
    private let toScopedState: KeyPath<Child.State, CreateScopedState<Key>>
    private let child: Child
    public func reduce(into state: inout Child.State, action: Child.Action) -> EffectTask<Child.Action> {
        self.child
            .dependency(\._scopeId, state[keyPath: self.toScopedState].id)
            .reduce(into: &state, action: action)
    }
}

/// A property wrapper that reads from scoped state.
///
/// The value is read from the scope when initialized. Any future
/// changes to the value must be updated expliclty using `observeState`.
@propertyWrapper
public struct ScopedState<Key: ScopedStateKey> where Key.Value: Equatable {
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

extension ScopedState: Equatable where Key.Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.wrappedValue == rhs.wrappedValue
    }
}
extension ScopedState: Sendable where Key.Value: Sendable {}

/// Actions that manage scoped state.
public enum ScopedStateAction<Key: ScopedStateKey> {
    case willChange(Key.Value)
}

extension ScopedStateAction: Equatable where Key.Value: Equatable {}
extension ScopedStateAction: Sendable where Key.Value: Sendable {}

extension ReducerProtocol {
    /// A higher-order reducer that monitors scoped state for changes and sends an action
    /// back into the system to synchronize with the current value.
    public func observeState<Key: ScopedStateKey>(
        _ toScopedState: WritableKeyPath<State, ScopedState<Key>>,
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
    let toScopedState: WritableKeyPath<ParentState, ScopedState<Key>>
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
    /// Set the initial value for scoped state.
    ///
    /// This is intended to be used for testing or previews where no parent
    /// feature provides a scope with `@CreateScopedState`.
    public mutating func createScopedState<Key: ScopedStateKey>(
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

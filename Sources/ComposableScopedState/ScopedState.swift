import ComposableArchitecture
import Foundation

public protocol SharedStateKey: Sendable, Equatable {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// A property wrapper that can share its value.
@propertyWrapper
public struct SharedState<Key: SharedStateKey> where Key.Value: Equatable {
    public var wrappedValue: Key.Value
    public var projectedValue: Self { self }
    public init(wrappedValue: Key.Value) {
        self.wrappedValue = wrappedValue
    }
}

extension SharedState: Equatable where Key.Value: Equatable {}
extension SharedState: Sendable where Key.Value: Sendable {}

/// A reducer that propagates shared state to its child reducer.
///
/// The shared state is only available to children of this reducer. Other reducers accessing
/// the same `SharedValueKey` key are unaffected.
public struct WithSharedState<Key: SharedStateKey, ParentState, ParentAction, Child: ReducerProtocol>: ReducerProtocol
where Key.Value: Equatable, ParentState == Child.State, ParentAction == Child.Action
{
    public init(
        _ toSharedState: KeyPath<ParentState, SharedState<Key>>,
        file: StaticString = #fileID,
        line: UInt8 = #line,
        @ReducerBuilder<Child.State, Child.Action> child: () -> Child
    ) {
        self.id = Identifier(file: "\(file)", line: line)
        self.toSharedState = toSharedState
        self.child = child()
    }
    private struct Identifier: Hashable {
        let file: String
        let line: UInt8
    }
    private let id: Identifier
    private let toSharedState: KeyPath<Child.State, SharedState<Key>>
    private let child: Child
    public func reduce(into state: inout Child.State, action: Child.Action) -> EffectTask<Child.Action> {
        let value = state[keyPath: self.toSharedState].wrappedValue
        return self.child
            .transformDependency(\._sharedValues) {
                $0 = $0.scope(
                    id: self.id,
                    key: Key.self,
                    value: value
                )
            }
            .reduce(into: &state, action: action)
    }
}

/// A property wrapper that reads a value from shared state.
@propertyWrapper
public struct SharedStateValue<Key: SharedStateKey> where Key.Value: Equatable {
    fileprivate var isObserving: Bool = false
    public fileprivate(set) var wrappedValue: Key.Value
    public fileprivate(set) var projectedValue: Self {
        get { self }
        set { self = newValue }
    }
    public init() {
        @Dependency(\._sharedValues) var sharedValues
        self.wrappedValue = sharedValues[Key.self]
    }
}

/// Actions sent when shared state changes.
enum SharedStateAction<Key: SharedStateKey> {
    /// Received by the reducer just before the value changes. You
    /// may compare the value in `State` to this value.
    case willChange(Key.Value)
}

extension SharedStateValue: Equatable where Key.Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}
extension SharedStateValue: Sendable where Key.Value: Sendable {}

extension SharedStateAction: Equatable where Key.Value: Equatable {}
extension SharedStateAction: Sendable where Key.Value: Sendable {}

extension ReducerProtocol {
    /// A higher-order reducer that monitors shared state for changes and sends an action
    /// back into the system to update state with the current value.
    func observeSharedState<Key: SharedStateKey>(
        _ toSharedState: WritableKeyPath<State, SharedStateValue<Key>>,
        action toSharedAction: CasePath<Action, SharedStateAction<Key>>
    ) -> some ReducerProtocol<State, Action>
    where Key.Value: Equatable
    {
        _ObserveSharedState(
            toSharedState: toSharedState,
            toSharedAction: toSharedAction,
            base: self
        )
    }
}

struct _ObserveSharedState<Key: SharedStateKey, ParentState, ParentAction, Base: ReducerProtocol>: ReducerProtocol
where Key.Value: Equatable, ParentState == Base.State, ParentAction == Base.Action {
    let toSharedState: WritableKeyPath<ParentState, SharedStateValue<Key>>
    let toSharedAction: CasePath<ParentAction, SharedStateAction<Key>>
    let base: Base
    @Dependency(\._sharedValues) var sharedValues
    func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<ParentAction> {
        let effects = self.base.reduce(into: &state, action: action)
        switch self.toSharedAction.extract(from: action) {
        case .willChange(let value):
            state[keyPath: toSharedState].wrappedValue = value
        case .none:
            break
        }
        guard
            !state[keyPath: self.toSharedState].isObserving
        else {
            return effects
        }
        state[keyPath: self.toSharedState].isObserving = true
        let initialValue = state[keyPath: self.toSharedState].wrappedValue
        return .merge(
            effects,
            .run { send in
                var firstValue = true
                for await value in self.sharedValues.observe(Key.self) {
                    if !firstValue || (firstValue && value != initialValue) {
                        await send(self.toSharedAction.embed(.willChange(value)))
                        firstValue = false
                    }
                }
            }
        )
    }
}

extension ReducerProtocol {
    func shareState<Key: SharedStateKey>(
        from fromSharedValue: KeyPath<State, SharedState<Key>>,
        to toSharedValue: WritableKeyPath<State, SharedStateValue<Key>>
    ) -> some ReducerProtocol<State, Action>
    where Key.Value: Equatable
    {
        Reduce { state, action in
            state[keyPath: toSharedValue].wrappedValue = state[keyPath: fromSharedValue].wrappedValue
            return self.reduce(into: &state, action: action)
        }
    }
}

extension DependencyValues {
    /// Set the initial value for shared state. This is intended to be used for testing or previews.
    mutating func sharedState<Key: SharedStateKey>(_ key: Key.Type, _ value: Key.Value, file: StaticString = #fileID, line: UInt8 = #line) {
        self._sharedValues = self._sharedValues.scope(
            id: Identifier(file: "\(file)", line: line),
            key: key,
            value: value
        )
    }
    private struct Identifier: Hashable {
        let file: String
        let line: UInt8
    }
}

import Combine

private var _scopedSharedValues = [ AnyHashable : _SharedValues ]()

struct _SharedValues: @unchecked Sendable {

    init(id: AnyHashable, values: Storage = [:]) {
        self.id = id
        self.storage = CurrentValueSubject(values)
    }

    typealias Storage = [ ObjectIdentifier : Any ]
    private let id: AnyHashable
    private var storage: CurrentValueSubject<Storage, Never>

    /// Create a copy with value.
    func scope<Key: SharedStateKey>(id: AnyHashable, key: Key.Type, value: Key.Value) -> _SharedValues {
        var values = self.storage.value
        values[ObjectIdentifier(key)] = value
        if let scope = _scopedSharedValues[id] {
            scope.storage.value = values
            return scope
        } else {
            let scope = _SharedValues(id: id, values: values)
            _scopedSharedValues[id] = scope
            return scope
        }
    }

    /// Read and write to a shared value.
    subscript<Key: SharedStateKey>(_ key: Key.Type) -> Key.Value {
        get {
            guard
                let value = self.storage.value[ObjectIdentifier(key)],
                let value = value as? Key.Value
            else {
                return key.defaultValue
            }
            return value
        }
        set {
            self.storage.value[ObjectIdentifier(key)] = newValue
        }
    }

    /// Observe changes to a shared value.
    func observe<Key: SharedStateKey>(_ key: Key.Type) -> AsyncStream<Key.Value> where Key.Value: Equatable {
        AsyncStream(
            self.storage
                .map { storage in
                    guard
                        let value = storage[ObjectIdentifier(key)],
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

extension _SharedValues: DependencyKey {
    static let liveValue = _SharedValues(id: "root")
}

extension DependencyValues {
    var _sharedValues: _SharedValues {
        get { self[_SharedValues.self] }
        set { self[_SharedValues.self] = newValue }
    }
}

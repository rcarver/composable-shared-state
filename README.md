# ComposableSharedState

Tools to share state from parent to child features in [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

## Status

Experimental. Targeting TCA `prerelease/1.0` for development.

## Goals

* An ergonomic way for child domains to stay in sync with data provided by a parent
* The parent doesn't need to know which children need the data
* The child doesn't need to know who's providing the data
* The child is functional in isolation
* The parent can decide which children receive the data, even sending different data to each child
* Children may modify shared state but the Parent stays in control


## Standard Usage

1. Define a `SharedStateKey`
2. In the parent domain:
    * Use the `@ParentState<Key>` property wrapper in `State` to read and write the value.
    * Wrap child reducers in `WithParentState` to propagate the value to that subtree of reducers.
3. In the child domain:
    * Use the `@ChildState<Key>` property wrapper to read the shared value
    * Use the `sharedState` higher-order reducer to update child state when the parent value changes.
    * The child reducer must receive an action to begin observing shared state

```swift
/// ✅ Define a key for shared state, with its default value.
struct CounterKey: SharedStateKey {
    static var defaultValue: Int = 4
}
struct ParentFeature: Reducer {
    struct State: Equatable {
        var child = ChildFeature.State()
        @ParentState<CounterKey> var counter
    }
    enum Action: Equatable {
        case child(ChildFeature.Action)
        case increment
    }
    init() {}
    var body: some Reducer<State, Action> {
        // ✅ Share `counter` with `child`
        WithParentState(\.$counter) {
            Scope(state: \.child, action: /Action.child) {
                ChildFeature()
            }
            Reduce { state, action in
                switch action {
                case .child:
                    return .none
                case .increment:
                    // ✅ `child` will update its value in response to this change.
                    state.counter += 1
                    return .none
                }
            }
        }
    }
}
struct ChildFeature: Reducer {
    struct State: Equatable {
        @ChildState<CounterKey> var counter
    }
    enum Action: Equatable {
        case counter(SharedStateAction<CounterKey>)
        case task // An action to initialize shared state observation
    }
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .counter:
                return .none
            case .task:
                return .none
            }
        }
        // ✅ Make *child* `counter` participate in shared state
        .sharedState(\.$counter, action: /Action.counter)
    }
}
```

## Advanced Usage: Child modifies ParentState 

1. In the parent domain:
    * Use the `sharedState` higher-order reducer to update parent state when its shared value changes.
    * The parent reducer must receive an action to begin observing shared state
3. In the child domain:
    * Use `@Dependency(\.parentState)` to set a new value
    
Because data flows from parent to child, changes to the parent will propagate down to
all children that participate in shared state.


```swift
struct ParentFeature: Reducer {
    struct State: Equatable {
        var child = ChildFeature.State()
        @ParentState<CounterKey> var counter
    }
    enum Action: Equatable {
        case child(ChildFeature.Action)
        case counter(SharedStateAction<CounterKey>)
        case task // An action to initialize shared state observation
    }
    init() {}
    var body: some Reducer<State, Action> {
        WithParentState(\.$counter) {
            Scope(state: \.child, action: /Action.child) {
                ChildFeature()
            }
            Reduce { state, action in
                switch action {
                case .child:
                    return .none
                case .counter:
                    return .none
                case .task:
                    return .none
                }
            }
            // ✅ Make *parent* `counter` participate in shared state
            .sharedState(\.$counter, action: /Action.counter)
        }
    }
}
struct ChildFeature: Reducer {
    struct State: Equatable {
        var value = 100
    }
    enum Action: Equatable {
        case updateParent
    }
    // ✅ Get access to parent state
    @Dependency(\.parentState) var parentState
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .updateParent:
                // ✅ Update the parent state
                self.parentState[CounterKey.self] = state.value
                return .none
            }
        }
    }
}
```

## License

This library is released under the MIT license. See LICENSE for details.

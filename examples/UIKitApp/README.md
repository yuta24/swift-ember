# UIKitApp

A storyboard-driven UIKit app: an app delegate, a scene delegate, a navigation
controller, a table view with prototype cells, outlets, a segue, and an
`@IBAction`. `XcodeApp` is the SwiftUI one; this is the shape the other half of
DESIGN.md section 13a is about, and the one that shows what `watch` says
differently about each kind of edit.

## Running it

Boot a simulator, then from the repository root:

```
xcodebuild -project examples/UIKitApp/UIKitApp.xcodeproj -scheme UIKitApp \
           -configuration Debug \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

swift-ember doctor --project examples/UIKitApp/UIKitApp.xcodeproj \
                    --scheme UIKitApp --sources examples/UIKitApp/Sources
swift-ember watch  --project examples/UIKitApp/UIKitApp.xcodeproj \
                    --scheme UIKitApp --sources examples/UIKitApp/Sources
```

Install and launch the built app, then edit one of the bodies below. The
`session` shown under the title is generated once per launch: if it does not
change, nothing restarted.

## What each edit does, and why they differ

**`Catalog.subtitle(for:)`** --- an ordinary Swift method the list calls from
`cellForRowAt`. The runtime sends a `reloadData()` after the patch lands, so
every row changes with no tap. Measured at 329 ms.

**`DetailViewController.refresh()`** --- called from `viewWillLayoutSubviews`.
Push the detail screen first; the label changes while you are looking at it,
without navigating away. Measured at 313 ms.

**`CatalogViewController.tableView(_:cellForRowAt:)`** --- an `@objc` override.
Its replacement arrives as an Objective-C category rather than a Swift
replacement record (section 13a.2), and reloading the list runs it.

**`DetailViewController.bump(_:)`** --- an `@IBAction`, so also `@objc`.
Nothing has to be refreshed for it: the next tap calls the new body.

**`RowCell.awakeFromNib()`** --- one-shot per cell, and `watch` says so:

```
  already ran: RowCell.awakeFromNib()
  replaced, but UIKit will not call it again for anything that
  already exists; the next instance of that type runs the new body
```

That is not a hedge. A table view keeps its cells in a reuse pool, so the cells
on screen keep the old body and the screen really does not change. The tool
says the change is not visible, and it is not.

**`AppDelegate.application(_:didFinishLaunchingWithOptions:)`** --- the one
where the advice is the opposite:

```
  already ran: AppDelegate.application(_:didFinishLaunchingWithOptions:)
  there is one of these per process, and relaunching starts from the
  built binary, so seeing this change takes a build
```

There is one delegate per process, and a relaunched process starts from the
binary on disk with no patch loaded. Telling you to make another one would be
advice that cannot work.

## What it does not do

The storyboard itself is not reloadable. Editing `Main.storyboard` changes a
resource the app read at launch; the daemon watches Swift sources and would not
see it. `viewDidLoad` on a controller already on screen is the same story as
`awakeFromNib` above --- navigate away and back, and the new controller runs the
new body.

fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Android

### android build

```sh
[bundle exec] fastlane android build
```

Build release AAB for Play Store

### android beta

```sh
[bundle exec] fastlane android beta
```

Build and upload to Play Store internal test track

### android promote

```sh
[bundle exec] fastlane android promote
```

Promote internal to production

### android metadata

```sh
[bundle exec] fastlane android metadata
```

Upload metadata and screenshots to Play Store

### android metadata_only

```sh
[bundle exec] fastlane android metadata_only
```

Upload metadata only (no screenshots)

----


## iOS

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload to TestFlight

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload metadata, screenshots, and URLs to App Store Connect

### ios metadata_only

```sh
[bundle exec] fastlane ios metadata_only
```

Upload metadata only (no screenshots)

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Take screenshots on all device sizes

### ios fetch_metadata

```sh
[bundle exec] fastlane ios fetch_metadata
```

Download existing metadata from App Store Connect

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).

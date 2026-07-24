# Contributing to Notch Master

Thanks for improving Notch Master.

## Before starting

- Search existing issues before opening a duplicate.
- Open an issue before a large behavior or architecture change.
- Keep contributions compatible with GPL-3.0.
- Do not remove upstream attribution, license files, or third-party notices.

## Development workflow

1. Fork and clone `PWL31/Notch-Master`.
2. Create a focused branch from `main`.
3. Make one logically scoped change.
4. Build the `boringNotch` scheme in Xcode.
5. Test the changed behavior on the relevant display configuration.
6. Open a pull request with the motivation, implementation summary, validation, and screenshots for UI changes.

Please avoid committing build output, local Xcode state, signing credentials, security-scoped bookmarks, or user-specific paths.

## Bug reports

Include:

- Notch Master version and macOS version.
- Mac/display setup, including whether each display has a physical notch.
- Exact reproduction steps and expected behavior.
- Screenshots or a short recording when the issue is visual.
- Relevant logs with credentials and personal information removed.

## Upstream changes

Notch Master is derived from [Boring Notch](https://github.com/TheBoredTeam/boring.notch). Changes that also benefit the upstream project may be proposed there separately, following the upstream contribution guide.

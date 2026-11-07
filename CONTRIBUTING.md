# Contributing to Daisyshot

Thanks for helping! Daisyshot is maintained in spare time, so replies can take a few days.

## Reporting bugs

Open an issue with the bug report template: your macOS version, Mac (Apple silicon or Intel), displays, and the steps
that show the problem. A screenshot or short recording helps most — blur anything private first.

## Pull requests

- Keep each pull request to one change, and say what it fixes or adds.
- Match the surrounding code: plain Swift / SwiftUI / AppKit, no third-party dependencies.
- `swift build` must finish without warnings, and the built-in checks must pass:
  `DAISYSHOT_SELFTEST=1 .build/debug/Daisyshot`. Add a check next to the code when you change logic.
- New user-facing text goes through `.loc` (or SwiftUI's localized text) and needs an entry in each
  `Localization/<language>/*.strings` file — run `python3 scripts/loc-check.py`.
- Don't add network access (beyond the update check), analytics or accounts: Daisyshot works offline.

## Translations

Interface text lives in `Localization/<language>/*.strings`; the glossaries in `Localization/GLOSSARY*.md` keep terms
consistent. Fixes to existing translations and new languages are welcome.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

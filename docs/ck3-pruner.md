# CK3 Pruner

`ck3-pruner` is the in-place successor to the copy-out `ck3-ai-pack-exporter` flow.

It keeps the existing regex fields:

- `IncludeDirectoryRegex`
- `IncludeFileRegex`
- `ExcludeDirectoryRegex`
- `ExcludeFileRegex`

The meaning changes from "copy matching files to OutputPath" to "keep matching files and delete the rest".

## Root Modes

`single` scans one directory and matches regexes relative to that directory.

`workshop_collection` scans each direct child directory as a separate mod root. This keeps old mod-relative rules like `^common(/|$)` working against Workshop content stored under numeric Steam folders.

## Safety

The tool always plans first.

Real deletion aborts when:

- no include rules are configured
- no roots are configured
- a root is the filesystem root
- `ReportDir` is inside a pruned root
- delete candidate ratio exceeds `MaxDeleteRatio`

Use `DryRun: true` for first runs and inspect:

```text
SUMMARY.txt
KEPT.txt
DELETED.txt
SKIPPED.txt
EMPTY_DIRS.txt
```


use std::{
    error::Error,
    fmt, fs, io,
    path::{Path, PathBuf},
};

use crate::{
    config::{Config, RootConfig, SourceInfo},
    report::{DirEntry, FileEntry, Report, SkipEntry},
    rules::{Decision, RuleSet},
};

#[derive(Debug)]
pub enum PruneError {
    Message(String),
    Io(io::Error),
}

impl fmt::Display for PruneError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Message(message) => f.write_str(message),
            Self::Io(err) => write!(f, "{err}"),
        }
    }
}

impl Error for PruneError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(err) => Some(err),
            Self::Message(_) => None,
        }
    }
}

impl From<io::Error> for PruneError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ScanRoot {
    kind: String,
    path: PathBuf,
}

pub struct Pruner {
    cfg: Config,
    rules: RuleSet,
    report: Report,
    directories: Vec<(String, PathBuf, String)>,
}

impl Pruner {
    pub fn new(cfg: Config, rule_set: RuleSet, source: SourceInfo) -> Self {
        Self {
            report: Report::new(cfg.clone(), source),
            cfg,
            rules: rule_set,
            directories: Vec::new(),
        }
    }

    pub fn run(&mut self) -> Result<Report, PruneError> {
        self.normalize_config()?;
        let roots = self.expand_roots()?;
        self.reject_report_inside_roots(&roots)?;

        for root in roots {
            self.walk_root(&root)?;
        }

        self.enforce_delete_ratio()?;

        if !self.cfg.dry_run {
            self.apply_deletes()?;
            if self.cfg.delete_empty_directories {
                self.remove_empty_dirs();
            }
        }

        let report_dir = self.cfg.report_dir.clone();
        self.report
            .write(&report_dir)
            .map_err(|err| PruneError::Message(format!("failed to write reports: {err}")))?;
        Ok(self.report.clone())
    }

    fn normalize_config(&mut self) -> Result<(), PruneError> {
        self.cfg.report_dir = self.cfg.report_dir.trim().to_string();
        if self.cfg.report_dir.is_empty() && !self.cfg.output_path.trim().is_empty() {
            self.cfg.report_dir = self.cfg.output_path.trim().to_string();
        }
        if self.cfg.report_dir.is_empty() {
            return Err(PruneError::Message("ReportDir cannot be empty".to_string()));
        }
        self.cfg.report_dir = absolute_path(&self.cfg.report_dir)?.display().to_string();

        let ratio = self.cfg.max_delete_ratio.unwrap_or(0.95);
        if !(0.0..=1.0).contains(&ratio) {
            return Err(PruneError::Message(format!(
                "MaxDeleteRatio must be between 0 and 1, got {ratio}"
            )));
        }
        self.cfg.max_delete_ratio = Some(ratio);
        self.report.config = self.cfg.clone();
        Ok(())
    }

    fn expand_roots(&self) -> Result<Vec<ScanRoot>, PruneError> {
        let mut roots = self.cfg.roots.clone();
        if roots.is_empty() {
            if !self.cfg.game_path.trim().is_empty() {
                roots.push(RootConfig {
                    kind: "base_game".to_string(),
                    path: self.cfg.game_path.trim().to_string(),
                    mode: "single".to_string(),
                });
            }
            if !self.cfg.workshop_path.trim().is_empty() {
                roots.push(RootConfig {
                    kind: "workshop_mod".to_string(),
                    path: self.cfg.workshop_path.trim().to_string(),
                    mode: "workshop_collection".to_string(),
                });
            }
        }

        if roots.is_empty() {
            return Err(PruneError::Message(
                "at least one Roots entry, GamePath, or WorkshopPath is required".to_string(),
            ));
        }

        let mut expanded = Vec::new();
        for root in roots {
            let path = root.path.trim();
            if path.is_empty() {
                return Err(PruneError::Message("root path cannot be empty".to_string()));
            }
            let abs = absolute_path(path)?;
            ensure_dir("root", &abs)?;
            if is_root_path(&abs) {
                return Err(PruneError::Message(format!(
                    "refusing to prune filesystem root: {}",
                    abs.display()
                )));
            }

            match root.mode.as_str() {
                "" | "single" => expanded.push(ScanRoot {
                    kind: if root.kind.is_empty() {
                        "root".to_string()
                    } else {
                        root.kind
                    },
                    path: abs,
                }),
                "workshop_collection" => {
                    let mut entries = fs::read_dir(&abs)
                        .map_err(|err| {
                            PruneError::Message(format!(
                                "failed to read workshop collection {}: {err}",
                                abs.display()
                            ))
                        })?
                        .collect::<Result<Vec<_>, io::Error>>()?;
                    entries.sort_by(|left, right| {
                        left.file_name()
                            .to_string_lossy()
                            .cmp(&right.file_name().to_string_lossy())
                    });
                    for entry in entries {
                        let file_type = match entry.file_type() {
                            Ok(file_type) => file_type,
                            Err(_) => continue,
                        };
                        if !file_type.is_dir() {
                            continue;
                        }
                        let folder = entry.file_name().to_string_lossy().to_string();
                        expanded.push(ScanRoot {
                            kind: format!("{}:{folder}", root.kind),
                            path: entry.path(),
                        });
                    }
                }
                other => {
                    return Err(PruneError::Message(format!(
                        "unsupported root mode {other:?}; expected single or workshop_collection"
                    )));
                }
            }
        }

        if expanded.is_empty() {
            return Err(PruneError::Message(
                "no concrete directories found to prune".to_string(),
            ));
        }
        Ok(expanded)
    }

    fn reject_report_inside_roots(&self, roots: &[ScanRoot]) -> Result<(), PruneError> {
        let report_dir = Path::new(&self.cfg.report_dir);
        for root in roots {
            if path_starts_with(report_dir, &root.path) {
                return Err(PruneError::Message(format!(
                    "ReportDir cannot be inside pruned root {}",
                    root.path.display()
                )));
            }
        }
        Ok(())
    }

    fn walk_root(&mut self, root: &ScanRoot) -> Result<(), PruneError> {
        self.walk_dir(root, &root.path, &root.path)
    }

    fn walk_dir(
        &mut self,
        root: &ScanRoot,
        root_abs: &Path,
        current_dir: &Path,
    ) -> Result<(), PruneError> {
        let mut entries = match fs::read_dir(current_dir) {
            Ok(entries) => {
                let mut collected = Vec::new();
                for entry in entries {
                    match entry {
                        Ok(entry) => collected.push(entry),
                        Err(err) => self.report.skipped.push(SkipEntry {
                            root_kind: root.kind.clone(),
                            path: normalize_rel_best_effort(root_abs, current_dir),
                            reason: err.to_string(),
                            is_error: true,
                        }),
                    }
                }
                collected
            }
            Err(err) => {
                self.report.skipped.push(SkipEntry {
                    root_kind: root.kind.clone(),
                    path: normalize_rel_best_effort(root_abs, current_dir),
                    reason: err.to_string(),
                    is_error: true,
                });
                return Ok(());
            }
        };
        entries.sort_by(|left, right| {
            left.file_name()
                .to_string_lossy()
                .cmp(&right.file_name().to_string_lossy())
        });

        for entry in entries {
            let current = entry.path();
            let rel = match normalize_rel(root_abs, &current) {
                Ok(rel) => rel,
                Err(err) => {
                    self.report.skipped.push(SkipEntry {
                        root_kind: root.kind.clone(),
                        path: path_to_slash(&current),
                        reason: err.to_string(),
                        is_error: true,
                    });
                    continue;
                }
            };

            let file_type = match entry.file_type() {
                Ok(file_type) => file_type,
                Err(err) => {
                    self.report.skipped.push(SkipEntry {
                        root_kind: root.kind.clone(),
                        path: rel,
                        reason: err.to_string(),
                        is_error: true,
                    });
                    continue;
                }
            };

            if file_type.is_symlink() {
                self.report.skipped.push(SkipEntry {
                    root_kind: root.kind.clone(),
                    path: rel,
                    reason: "skipping symlink".to_string(),
                    is_error: false,
                });
                continue;
            }

            if file_type.is_dir() {
                self.directories
                    .push((root.kind.clone(), current.clone(), rel.clone()));
                self.walk_dir(root, root_abs, &current)?;
                continue;
            }

            let metadata = match entry.metadata() {
                Ok(metadata) => metadata,
                Err(err) => {
                    self.report.skipped.push(SkipEntry {
                        root_kind: root.kind.clone(),
                        path: rel,
                        reason: err.to_string(),
                        is_error: true,
                    });
                    continue;
                }
            };

            let decision = self.rules.should_keep_file(&rel);
            self.record_file(root, root_abs, current, rel, metadata.len(), decision);
        }

        Ok(())
    }

    fn record_file(
        &mut self,
        root: &ScanRoot,
        root_abs: &Path,
        current: PathBuf,
        rel: String,
        size: u64,
        decision: Decision,
    ) {
        let entry = FileEntry {
            root_kind: root.kind.clone(),
            root_path: root_abs.display().to_string(),
            rel,
            size,
            reason: describe_decision(&decision),
            dry_run: self.cfg.dry_run,
        };

        if decision.keep {
            self.report.kept.push(entry);
        } else {
            self.report.deleted.push(entry);
        }

        if !decision.keep && self.cfg.verbose {
            eprintln!("delete candidate: {}", current.display());
        }
    }

    fn enforce_delete_ratio(&mut self) -> Result<(), PruneError> {
        if self.cfg.dry_run {
            return Ok(());
        }
        let max_ratio = self.cfg.max_delete_ratio.unwrap_or(0.95);
        let ratio = self.report.delete_ratio();
        if ratio > max_ratio {
            self.report.aborted = format!(
                "delete ratio {:.4} exceeds MaxDeleteRatio {:.4}",
                ratio, max_ratio
            );
            let report_dir = self.cfg.report_dir.clone();
            let _ = self.report.write(&report_dir);
            return Err(PruneError::Message(self.report.aborted.clone()));
        }
        Ok(())
    }

    fn apply_deletes(&mut self) -> Result<(), PruneError> {
        let planned = self.report.deleted.clone();
        self.report.deleted.clear();

        for mut entry in planned {
            let path = Path::new(&entry.root_path).join(path_from_slash(&entry.rel));
            match fs::remove_file(&path) {
                Ok(()) => {
                    entry.dry_run = false;
                    self.report.deleted.push(entry);
                }
                Err(err) => self.report.skipped.push(SkipEntry {
                    root_kind: entry.root_kind,
                    path: entry.rel,
                    reason: format!("delete failed: {err}"),
                    is_error: true,
                }),
            }
        }
        Ok(())
    }

    fn remove_empty_dirs(&mut self) {
        self.directories.sort_by(|left, right| {
            right
                .1
                .components()
                .count()
                .cmp(&left.1.components().count())
        });

        for (kind, path, rel) in self.directories.clone() {
            if rel.is_empty() || self.rules.protected_path(&rel).0 {
                continue;
            }
            match fs::remove_dir(&path) {
                Ok(()) => self.report.removed_empty_dirs.push(DirEntry {
                    root_kind: kind,
                    rel,
                    dry_run: false,
                }),
                Err(err) if err.kind() == io::ErrorKind::NotFound => {}
                Err(err) if err.kind() == io::ErrorKind::DirectoryNotEmpty => {}
                Err(err) => self.report.skipped.push(SkipEntry {
                    root_kind: kind,
                    path: rel,
                    reason: format!("remove empty dir failed: {err}"),
                    is_error: true,
                }),
            }
        }
    }
}

fn describe_decision(decision: &Decision) -> String {
    let mut parts = vec![decision.reason.clone()];
    if !decision.include_pattern.is_empty() {
        parts.push(format!("include={}", decision.include_pattern));
    }
    if !decision.exclude_pattern.is_empty() {
        parts.push(format!("exclude={}", decision.exclude_pattern));
    }
    if !decision.protected_pattern.is_empty() {
        parts.push(format!("protected={}", decision.protected_pattern));
    }
    parts.join("; ")
}

fn ensure_dir(label: &str, dir: &Path) -> Result<(), PruneError> {
    let info = fs::metadata(dir)
        .map_err(|err| PruneError::Message(format!("{label} cannot be accessed: {err}")))?;
    if !info.is_dir() {
        return Err(PruneError::Message(format!(
            "{label} is not a directory: {}",
            dir.display()
        )));
    }
    Ok(())
}

fn absolute_path(path: impl AsRef<Path>) -> io::Result<PathBuf> {
    std::path::absolute(path)
}

fn is_root_path(path: &Path) -> bool {
    path.parent().is_none() || path.parent().is_some_and(|parent| parent == path)
}

fn path_starts_with(target: &Path, root: &Path) -> bool {
    #[cfg(windows)]
    {
        let target_components = target.components().collect::<Vec<_>>();
        let root_components = root.components().collect::<Vec<_>>();
        root_components.len() <= target_components.len()
            && root_components
                .iter()
                .zip(target_components.iter())
                .all(|(left, right)| {
                    left.as_os_str()
                        .to_string_lossy()
                        .eq_ignore_ascii_case(&right.as_os_str().to_string_lossy())
                })
    }
    #[cfg(not(windows))]
    {
        target.starts_with(root)
    }
}

fn normalize_rel(root_abs: &Path, current: &Path) -> io::Result<String> {
    let rel = current.strip_prefix(root_abs).map_err(io::Error::other)?;
    Ok(path_to_slash(rel))
}

fn normalize_rel_best_effort(root_abs: &Path, current: &Path) -> String {
    normalize_rel(root_abs, current).unwrap_or_else(|_| path_to_slash(current))
}

fn path_to_slash(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn path_from_slash(path: &str) -> PathBuf {
    let mut result = PathBuf::new();
    for segment in path.split('/') {
        if !segment.is_empty() {
            result.push(segment);
        }
    }
    result
}

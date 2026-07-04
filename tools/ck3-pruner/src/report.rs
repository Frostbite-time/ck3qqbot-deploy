use std::{fmt, fs, io, path::Path};

use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use crate::config::{Config, SourceInfo};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileEntry {
    pub root_kind: String,
    pub root_path: String,
    pub rel: String,
    pub size: u64,
    pub reason: String,
    pub dry_run: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SkipEntry {
    pub root_kind: String,
    pub path: String,
    pub reason: String,
    pub is_error: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DirEntry {
    pub root_kind: String,
    pub rel: String,
    pub dry_run: bool,
}

#[derive(Clone, Debug)]
pub struct Report {
    pub started_at: OffsetDateTime,
    pub ended_at: OffsetDateTime,
    pub config: Config,
    pub source: SourceInfo,
    pub kept: Vec<FileEntry>,
    pub deleted: Vec<FileEntry>,
    pub skipped: Vec<SkipEntry>,
    pub removed_empty_dirs: Vec<DirEntry>,
    pub aborted: String,
}

impl Report {
    pub fn new(cfg: Config, source: SourceInfo) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            started_at: now,
            ended_at: now,
            config: cfg,
            source,
            kept: Vec::new(),
            deleted: Vec::new(),
            skipped: Vec::new(),
            removed_empty_dirs: Vec::new(),
            aborted: String::new(),
        }
    }

    pub fn total_files(&self) -> usize {
        self.kept.len() + self.deleted.len()
    }

    pub fn deleted_bytes(&self) -> u64 {
        self.deleted.iter().map(|entry| entry.size).sum()
    }

    pub fn kept_bytes(&self) -> u64 {
        self.kept.iter().map(|entry| entry.size).sum()
    }

    pub fn delete_ratio(&self) -> f64 {
        let total = self.total_files();
        if total == 0 {
            0.0
        } else {
            self.deleted.len() as f64 / total as f64
        }
    }

    pub fn error_count(&self) -> usize {
        self.skipped.iter().filter(|entry| entry.is_error).count()
    }

    pub fn write(&mut self, report_dir: impl AsRef<Path>) -> io::Result<()> {
        self.ended_at = OffsetDateTime::now_utc();
        let report_dir = report_dir.as_ref();
        fs::create_dir_all(report_dir)?;

        fs::write(report_dir.join("SUMMARY.txt"), self.summary_text())?;
        fs::write(report_dir.join("KEPT.txt"), self.kept_text())?;
        fs::write(report_dir.join("DELETED.txt"), self.deleted_text())?;
        fs::write(report_dir.join("SKIPPED.txt"), self.skipped_text())?;
        fs::write(report_dir.join("EMPTY_DIRS.txt"), self.empty_dirs_text())?;
        Ok(())
    }

    fn summary_text(&self) -> String {
        let mut out = String::new();
        push_line(&mut out, format_args!("CK3 Pruner Summary"));
        push_line(
            &mut out,
            format_args!("StartedAt: {}", format_time(self.started_at)),
        );
        push_line(
            &mut out,
            format_args!("EndedAt: {}", format_time(self.ended_at)),
        );
        push_line(
            &mut out,
            format_args!(
                "Mode: {}",
                if self.config.dry_run {
                    "dry-run"
                } else {
                    "delete"
                }
            ),
        );
        push_line(
            &mut out,
            format_args!("RuleSource: {}", self.source.summary()),
        );
        push_line(
            &mut out,
            format_args!("ReportDir: {}", self.config.report_dir),
        );
        push_line(
            &mut out,
            format_args!(
                "MaxDeleteRatio: {:.4}",
                self.config.max_delete_ratio.unwrap_or(0.95)
            ),
        );
        push_line(&mut out, format_args!("TotalFiles: {}", self.total_files()));
        push_line(&mut out, format_args!("KeptFiles: {}", self.kept.len()));
        push_line(
            &mut out,
            format_args!("DeleteCandidates: {}", self.deleted.len()),
        );
        push_line(
            &mut out,
            format_args!("DeleteRatio: {:.4}", self.delete_ratio()),
        );
        push_line(
            &mut out,
            format_args!(
                "KeptBytes: {} ({})",
                self.kept_bytes(),
                format_bytes(self.kept_bytes())
            ),
        );
        push_line(
            &mut out,
            format_args!(
                "DeleteCandidateBytes: {} ({})",
                self.deleted_bytes(),
                format_bytes(self.deleted_bytes())
            ),
        );
        push_line(
            &mut out,
            format_args!("RemovedEmptyDirs: {}", self.removed_empty_dirs.len()),
        );
        push_line(
            &mut out,
            format_args!("SkippedEntries: {}", self.skipped.len()),
        );
        push_line(&mut out, format_args!("Errors: {}", self.error_count()));
        if !self.aborted.is_empty() {
            push_line(&mut out, format_args!("Aborted: {}", self.aborted));
        }
        out
    }

    fn kept_text(&self) -> String {
        let mut entries = self.kept.clone();
        sort_file_entries(&mut entries);
        let mut out = String::new();
        for entry in entries {
            push_line(
                &mut out,
                format_args!(
                    "KEEP\t{}\t{}\t{}\t{}",
                    entry.root_kind, entry.size, entry.rel, entry.reason
                ),
            );
        }
        out
    }

    fn deleted_text(&self) -> String {
        let mut entries = self.deleted.clone();
        sort_file_entries(&mut entries);
        let mut out = String::new();
        for entry in entries {
            let action = if entry.dry_run {
                "WOULD_DELETE"
            } else {
                "DELETE"
            };
            push_line(
                &mut out,
                format_args!(
                    "{}\t{}\t{}\t{}\t{}",
                    action, entry.root_kind, entry.size, entry.rel, entry.reason
                ),
            );
        }
        out
    }

    fn skipped_text(&self) -> String {
        let mut entries = self.skipped.clone();
        entries.sort_by(|left, right| {
            left.root_kind
                .cmp(&right.root_kind)
                .then_with(|| left.path.cmp(&right.path))
        });

        let mut out = String::new();
        for entry in entries {
            let level = if entry.is_error { "ERROR" } else { "SKIP" };
            push_line(
                &mut out,
                format_args!(
                    "{}\t{}\t{}\t{}",
                    level, entry.root_kind, entry.path, entry.reason
                ),
            );
        }
        out
    }

    fn empty_dirs_text(&self) -> String {
        let mut entries = self.removed_empty_dirs.clone();
        entries.sort_by(|left, right| {
            left.root_kind
                .cmp(&right.root_kind)
                .then_with(|| left.rel.cmp(&right.rel))
        });

        let mut out = String::new();
        for entry in entries {
            let action = if entry.dry_run {
                "WOULD_REMOVE_DIR"
            } else {
                "REMOVE_DIR"
            };
            push_line(
                &mut out,
                format_args!("{}\t{}\t{}", action, entry.root_kind, entry.rel),
            );
        }
        out
    }
}

pub fn format_bytes(bytes: u64) -> String {
    const UNIT: f64 = 1024.0;
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64;
    for suffix in ["KiB", "MiB", "GiB", "TiB"] {
        value /= UNIT;
        if value < UNIT {
            return format!("{value:.2} {suffix}");
        }
    }
    format!("{:.2} PiB", value / UNIT)
}

fn sort_file_entries(entries: &mut [FileEntry]) {
    entries.sort_by(|left, right| {
        left.root_kind
            .cmp(&right.root_kind)
            .then_with(|| left.rel.cmp(&right.rel))
    });
}

fn push_line(out: &mut String, args: fmt::Arguments<'_>) {
    use fmt::Write as _;

    out.write_fmt(args).expect("writing to String cannot fail");
    out.push('\n');
}

fn format_time(value: OffsetDateTime) -> String {
    value
        .format(&Rfc3339)
        .unwrap_or_else(|_| value.unix_timestamp().to_string())
}

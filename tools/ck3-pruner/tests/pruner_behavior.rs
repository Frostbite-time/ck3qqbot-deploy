use std::{fs, path::PathBuf};

use ck3_pruner::{
    config::{Config, RootConfig, RuleConfig, SourceInfo},
    prune::{PruneError, Pruner},
    report::Report,
    rules::RuleSet,
};
use tempfile::tempdir;

#[test]
fn dry_run_plans_deletes_without_removing_files() {
    let tmp = tempdir().unwrap();
    let root = tmp.path().join("game");
    let report_dir = tmp.path().join("reports");

    write_file(root.join("common/script.txt"), "keep");
    write_file(root.join("gfx/model.mesh"), "delete");
    write_file(root.join("descriptor.mod"), "descriptor");

    let report = run_pruner(Config {
        roots: vec![RootConfig {
            kind: "base_game".to_string(),
            path: root.display().to_string(),
            mode: "single".to_string(),
        }],
        report_dir: report_dir.display().to_string(),
        dry_run: true,
        include_directory_regex: vec![RuleConfig {
            pattern: r"^common(/|$)".to_string(),
            force: false,
        }],
        include_file_regex: vec![RuleConfig {
            pattern: r"^[^/]+\.mod$".to_string(),
            force: true,
        }],
        exclude_file_regex: vec![RuleConfig {
            pattern: r"\.(mesh|dds)$".to_string(),
            force: false,
        }],
        ..Config::default()
    })
    .unwrap();

    assert_exists(root.join("common/script.txt"));
    assert_exists(root.join("gfx/model.mesh"));
    assert_exists(root.join("descriptor.mod"));
    assert!(
        report
            .kept
            .iter()
            .any(|entry| entry.rel == "common/script.txt")
    );
    assert!(
        report
            .kept
            .iter()
            .any(|entry| entry.rel == "descriptor.mod")
    );
    assert!(
        report
            .deleted
            .iter()
            .any(|entry| entry.rel == "gfx/model.mesh")
    );
    assert_exists(report_dir.join("SUMMARY.txt"));
}

#[test]
fn real_run_deletes_candidates_and_empty_dirs() {
    let tmp = tempdir().unwrap();
    let root = tmp.path().join("game");
    let report_dir = tmp.path().join("reports");

    write_file(root.join("common/script.txt"), "keep");
    write_file(root.join("gfx/models/model.mesh"), "delete");

    let report = run_pruner(Config {
        roots: vec![RootConfig {
            kind: "base_game".to_string(),
            path: root.display().to_string(),
            mode: "single".to_string(),
        }],
        report_dir: report_dir.display().to_string(),
        dry_run: false,
        max_delete_ratio: Some(1.0),
        include_directory_regex: vec![RuleConfig {
            pattern: r"^common(/|$)".to_string(),
            force: false,
        }],
        exclude_file_regex: vec![RuleConfig {
            pattern: r"\.mesh$".to_string(),
            force: false,
        }],
        ..Config::default()
    })
    .unwrap();

    assert_exists(root.join("common/script.txt"));
    assert_missing(root.join("gfx/models/model.mesh"));
    assert_missing(root.join("gfx/models"));
    assert!(
        report
            .deleted
            .iter()
            .any(|entry| entry.rel == "gfx/models/model.mesh")
    );
}

#[test]
fn delete_ratio_guard_aborts_before_removing_files() {
    let tmp = tempdir().unwrap();
    let root = tmp.path().join("game");
    let report_dir = tmp.path().join("reports");

    write_file(root.join("gfx/model.mesh"), "delete");

    let err = run_pruner(Config {
        roots: vec![RootConfig {
            kind: "base_game".to_string(),
            path: root.display().to_string(),
            mode: "single".to_string(),
        }],
        report_dir: report_dir.display().to_string(),
        dry_run: false,
        max_delete_ratio: Some(0.5),
        include_directory_regex: vec![RuleConfig {
            pattern: r"^common(/|$)".to_string(),
            force: false,
        }],
        ..Config::default()
    })
    .unwrap_err();

    assert!(matches!(err, PruneError::Message(_)));
    assert_exists(root.join("gfx/model.mesh"));
    assert_exists(report_dir.join("SUMMARY.txt"));
}

#[test]
fn workshop_collection_scans_each_mod_with_mod_relative_rules() {
    let tmp = tempdir().unwrap();
    let workshop = tmp.path().join("workshop");
    let report_dir = tmp.path().join("reports");
    let mod_root = workshop.join("123");

    write_file(mod_root.join("common/mod_script.txt"), "keep");
    write_file(mod_root.join("gfx/model.mesh"), "delete");

    run_pruner(Config {
        roots: vec![RootConfig {
            kind: "workshop_mod".to_string(),
            path: workshop.display().to_string(),
            mode: "workshop_collection".to_string(),
        }],
        report_dir: report_dir.display().to_string(),
        dry_run: false,
        max_delete_ratio: Some(1.0),
        include_directory_regex: vec![RuleConfig {
            pattern: r"^common(/|$)".to_string(),
            force: false,
        }],
        exclude_file_regex: vec![RuleConfig {
            pattern: r"\.mesh$".to_string(),
            force: false,
        }],
        ..Config::default()
    })
    .unwrap();

    assert_exists(mod_root.join("common/mod_script.txt"));
    assert_missing(mod_root.join("gfx/model.mesh"));
}

fn run_pruner(cfg: Config) -> Result<Report, PruneError> {
    let set = RuleSet::compile(&cfg).unwrap();
    let mut pruner = Pruner::new(cfg, set, SourceInfo::default());
    pruner.run()
}

fn write_file(path: PathBuf, content: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, content).unwrap();
}

fn assert_exists(path: PathBuf) {
    assert!(path.exists(), "expected {} to exist", path.display());
}

fn assert_missing(path: PathBuf) {
    assert!(!path.exists(), "expected {} to be missing", path.display());
}

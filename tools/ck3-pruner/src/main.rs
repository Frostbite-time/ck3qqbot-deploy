use std::process;

use ck3_pruner::{config, prune::Pruner, rules};

fn main() {
    let (cfg, source) = match config::load(std::env::args().skip(1)) {
        Ok(result) => result,
        Err(config::ConfigError::Help) => {
            print!("{}", config::usage());
            return;
        }
        Err(err) => {
            eprint!("error: {err}\n\n{}", config::usage());
            process::exit(2);
        }
    };

    let rule_set = match rules::RuleSet::compile(&cfg) {
        Ok(rule_set) => rule_set,
        Err(err) => {
            eprintln!("rule error: {err}");
            process::exit(2);
        }
    };

    let mut pruner = Pruner::new(cfg, rule_set, source);
    let report = match pruner.run() {
        Ok(report) => report,
        Err(err) => {
            eprintln!("prune failed: {err}");
            process::exit(1);
        }
    };

    let mode = if report.config.dry_run {
        "dry-run"
    } else {
        "prune"
    };
    println!(
        "{mode} complete: kept {}, delete candidates {}, candidate bytes {}, reports {}",
        report.kept.len(),
        report.deleted.len(),
        ck3_pruner::report::format_bytes(report.deleted_bytes()),
        report.config.report_dir
    );
}

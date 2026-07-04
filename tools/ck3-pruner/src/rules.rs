use std::{error::Error, fmt};

use regex::Regex;

use crate::config::{Config, RuleConfig};

#[derive(Debug)]
pub struct Rule {
    pub pattern: String,
    pub force: bool,
    re: Regex,
}

#[derive(Debug, Default)]
pub struct RuleSet {
    include_dirs: Vec<Rule>,
    include_files: Vec<Rule>,
    exclude_dirs: Vec<Rule>,
    exclude_files: Vec<Rule>,
    protected_paths: Vec<Rule>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Decision {
    pub keep: bool,
    pub forced: bool,
    pub reason: String,
    pub include_pattern: String,
    pub exclude_pattern: String,
    pub protected_pattern: String,
}

#[derive(Debug)]
pub struct RuleError(String);

impl fmt::Display for RuleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl Error for RuleError {}

impl RuleSet {
    pub fn compile(cfg: &Config) -> Result<Self, RuleError> {
        let include_dirs =
            compile_rule_list("IncludeDirectoryRegex", &cfg.include_directory_regex)?;
        let include_files = compile_rule_list("IncludeFileRegex", &cfg.include_file_regex)?;
        let exclude_dirs =
            compile_rule_list("ExcludeDirectoryRegex", &cfg.exclude_directory_regex)?;
        let exclude_files = compile_rule_list("ExcludeFileRegex", &cfg.exclude_file_regex)?;
        let protected_paths = compile_rule_list("ProtectedPathRegex", &cfg.protected_path_regex)?;

        if include_dirs.is_empty() && include_files.is_empty() {
            return Err(RuleError(
                "at least one include directory or file rule is required".to_string(),
            ));
        }

        Ok(Self {
            include_dirs,
            include_files,
            exclude_dirs,
            exclude_files,
            protected_paths,
        })
    }

    pub fn protected_path(&self, path: &str) -> (bool, String) {
        first_match(&self.protected_paths, path)
    }

    pub fn should_keep_file(&self, path: &str) -> Decision {
        let (protected, protected_pattern) = self.protected_path(path);
        if protected {
            return Decision {
                keep: true,
                reason: "protected path".to_string(),
                protected_pattern,
                ..Decision::default()
            };
        }

        let (include_file, include_file_pattern, include_file_force) =
            first_file_include_match(&self.include_files, path);
        if include_file && include_file_force {
            return Decision {
                keep: true,
                forced: true,
                reason: "forced include file".to_string(),
                include_pattern: include_file_pattern,
                ..Decision::default()
            };
        }

        let (dir_excluded, dir_exclude_pattern) = first_match(&self.exclude_dirs, path);
        let dir_force_included = self
            .include_dirs
            .iter()
            .any(|rule| rule.force && rule.re.is_match(path));
        if dir_excluded && !dir_force_included {
            return Decision {
                keep: false,
                reason: "matched ExcludeDirectoryRegex".to_string(),
                exclude_pattern: dir_exclude_pattern,
                ..Decision::default()
            };
        }

        let (include_dir, include_dir_pattern) = first_match(&self.include_dirs, path);
        if !include_dir && !include_file {
            return Decision {
                keep: false,
                reason: "matched no include rule".to_string(),
                ..Decision::default()
            };
        }

        let include_pattern = if include_file_pattern.is_empty() {
            include_dir_pattern
        } else {
            include_file_pattern
        };

        let (file_excluded, file_exclude_pattern) = first_match(&self.exclude_files, path);
        if file_excluded {
            return Decision {
                keep: false,
                reason: "matched ExcludeFileRegex".to_string(),
                include_pattern,
                exclude_pattern: file_exclude_pattern,
                ..Decision::default()
            };
        }

        Decision {
            keep: true,
            reason: "matched include rule".to_string(),
            include_pattern,
            forced: dir_force_included,
            ..Decision::default()
        }
    }
}

fn compile_rule_list(name: &str, specs: &[RuleConfig]) -> Result<Vec<Rule>, RuleError> {
    let mut rules = Vec::with_capacity(specs.len());
    for (index, spec) in specs.iter().enumerate() {
        if spec.pattern.is_empty() {
            return Err(RuleError(format!("{name}[{index}] regex is empty")));
        }
        let re = Regex::new(&spec.pattern).map_err(|err| {
            RuleError(format!(
                "{name}[{index}] regex {:?} is invalid: {err}",
                spec.pattern
            ))
        })?;
        rules.push(Rule {
            pattern: spec.pattern.clone(),
            force: spec.force,
            re,
        });
    }
    Ok(rules)
}

fn first_match(rules: &[Rule], path: &str) -> (bool, String) {
    for rule in rules {
        if rule.re.is_match(path) {
            return (true, rule.pattern.clone());
        }
    }
    (false, String::new())
}

fn first_file_include_match(rules: &[Rule], path: &str) -> (bool, String, bool) {
    for rule in rules {
        if rule.re.is_match(path) {
            return (true, rule.pattern.clone(), rule.force);
        }
    }
    (false, String::new(), false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, RuleConfig};

    #[test]
    fn forced_file_include_keeps_file() {
        let set = RuleSet::compile(&Config {
            include_file_regex: vec![RuleConfig {
                pattern: r"^descriptor\.mod$".to_string(),
                force: true,
            }],
            exclude_file_regex: vec![RuleConfig {
                pattern: r"\.mod$".to_string(),
                force: false,
            }],
            ..Config::default()
        })
        .unwrap();

        let decision = set.should_keep_file("descriptor.mod");
        assert!(decision.keep);
        assert!(decision.forced);
    }

    #[test]
    fn ordinary_include_still_loses_to_file_exclude() {
        let set = RuleSet::compile(&Config {
            include_directory_regex: vec![RuleConfig {
                pattern: r"^common(/|$)".to_string(),
                force: false,
            }],
            exclude_file_regex: vec![RuleConfig {
                pattern: r"\.dds$".to_string(),
                force: false,
            }],
            ..Config::default()
        })
        .unwrap();

        assert!(set.should_keep_file("common/script.txt").keep);
        assert!(!set.should_keep_file("common/texture.dds").keep);
    }

    #[test]
    fn protected_path_wins_before_rules() {
        let set = RuleSet::compile(&Config {
            include_directory_regex: vec![RuleConfig {
                pattern: r"^common(/|$)".to_string(),
                force: false,
            }],
            exclude_file_regex: vec![RuleConfig {
                pattern: r".*".to_string(),
                force: false,
            }],
            protected_path_regex: vec![RuleConfig {
                pattern: r"^steam\.acf$".to_string(),
                force: false,
            }],
            ..Config::default()
        })
        .unwrap();

        assert!(set.should_keep_file("steam.acf").keep);
    }
}

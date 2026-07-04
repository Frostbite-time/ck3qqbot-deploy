use std::{
    collections::HashSet,
    error::Error,
    fmt, fs, io,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct RuleConfig {
    pub pattern: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub force: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(default)]
pub struct RootConfig {
    #[serde(rename = "Kind")]
    pub kind: String,
    #[serde(rename = "Path")]
    pub path: String,
    #[serde(rename = "Mode")]
    pub mode: String,
}

impl Default for RootConfig {
    fn default() -> Self {
        Self {
            kind: "root".to_string(),
            path: String::new(),
            mode: "single".to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default)]
pub struct Config {
    #[serde(rename = "Roots")]
    pub roots: Vec<RootConfig>,

    #[serde(rename = "GamePath")]
    pub game_path: String,
    #[serde(rename = "WorkshopPath")]
    pub workshop_path: String,
    #[serde(rename = "OutputPath")]
    pub output_path: String,
    #[serde(rename = "ReportDir")]
    pub report_dir: String,

    #[serde(rename = "DryRun")]
    pub dry_run: bool,
    #[serde(rename = "Verbose")]
    pub verbose: bool,
    #[serde(rename = "DeleteEmptyDirectories")]
    pub delete_empty_directories: bool,
    #[serde(rename = "MaxDeleteRatio")]
    pub max_delete_ratio: Option<f64>,

    #[serde(rename = "IncludeDirectoryRegex")]
    pub include_directory_regex: Vec<RuleConfig>,
    #[serde(rename = "IncludeFileRegex")]
    pub include_file_regex: Vec<RuleConfig>,
    #[serde(rename = "ExcludeDirectoryRegex")]
    pub exclude_directory_regex: Vec<RuleConfig>,
    #[serde(rename = "ExcludeFileRegex")]
    pub exclude_file_regex: Vec<RuleConfig>,
    #[serde(rename = "ProtectedPathRegex")]
    pub protected_path_regex: Vec<RuleConfig>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            roots: Vec::new(),
            game_path: String::new(),
            workshop_path: String::new(),
            output_path: String::new(),
            report_dir: String::new(),
            dry_run: true,
            verbose: false,
            delete_empty_directories: true,
            max_delete_ratio: Some(0.95),
            include_directory_regex: Vec::new(),
            include_file_regex: Vec::new(),
            exclude_directory_regex: Vec::new(),
            exclude_file_regex: Vec::new(),
            protected_path_regex: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SourceInfo {
    pub config_path: String,
    pub used_config: bool,
    pub used_local_config: bool,
    pub cli_overrides: Vec<String>,
}

impl SourceInfo {
    pub fn summary(&self) -> String {
        let mut parts = Vec::with_capacity(3);
        if self.used_local_config {
            parts.push("local config.json".to_string());
        } else if self.used_config {
            parts.push(format!("config: {}", self.config_path));
        }
        if !self.cli_overrides.is_empty() {
            parts.push(format!("CLI overrides: {}", self.cli_overrides.join(", ")));
        }
        if parts.is_empty() {
            "CLI only".to_string()
        } else {
            parts.join("; ")
        }
    }
}

#[derive(Debug)]
pub enum ConfigError {
    Help,
    Message(String),
    Io(io::Error),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Help => write!(f, "help requested"),
            Self::Message(message) => f.write_str(message),
            Self::Io(err) => write!(f, "{err}"),
        }
    }
}

impl Error for ConfigError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(err) => Some(err),
            Self::Help | Self::Message(_) => None,
        }
    }
}

impl From<io::Error> for ConfigError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Debug, Default)]
struct CliOptions {
    config_path: String,
    use_local_config: bool,
    report_dir: String,
    dry_run: Option<bool>,
    delete_empty_directories: Option<bool>,
    max_delete_ratio: Option<f64>,
    roots: Vec<RootConfig>,
    visited: HashSet<String>,
}

pub fn load<I, S>(args: I) -> Result<(Config, SourceInfo), ConfigError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let opts = parse_args(args)?;

    if opts.use_local_config && !opts.config_path.is_empty() {
        return Err(ConfigError::Message(
            "-config and -use-local-config cannot be used together".to_string(),
        ));
    }

    let mut config_path = opts.config_path.clone();
    let mut source = SourceInfo::default();
    if opts.use_local_config {
        config_path = PathBuf::from(".").join("config.json").display().to_string();
        match fs::metadata(&config_path) {
            Ok(_) => {}
            Err(err) if err.kind() == io::ErrorKind::NotFound => {
                return Err(ConfigError::Message(
                    "current directory does not contain config.json".to_string(),
                ));
            }
            Err(err) => {
                return Err(ConfigError::Message(format!(
                    "checking config.json failed: {err}"
                )));
            }
        }
        source.used_local_config = true;
    }

    if config_path.is_empty() {
        return Err(ConfigError::Message(
            "no config source; use -config or -use-local-config".to_string(),
        ));
    }

    let mut cfg = read_config(&config_path)?;
    source.used_config = true;
    source.config_path = config_path;

    apply_cli_overrides(&mut cfg, &opts, &mut source);
    Ok((cfg, source))
}

fn parse_args<I, S>(args: I) -> Result<CliOptions, ConfigError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let args: Vec<String> = args.into_iter().map(Into::into).collect();
    let mut opts = CliOptions::default();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if arg == "--" {
            break;
        }
        if !arg.starts_with('-') || arg == "-" {
            break;
        }

        let trimmed = arg.trim_start_matches('-');
        if trimmed == "h" || trimmed == "help" {
            return Err(ConfigError::Help);
        }
        let (name, inline_value) = match trimmed.split_once('=') {
            Some((name, value)) => (name, Some(value.to_string())),
            None => (trimmed, None),
        };

        match name {
            "config" => {
                opts.config_path = take_value("config", inline_value, &args, &mut index)?;
                opts.visited.insert(name.to_string());
            }
            "use-local-config" => {
                opts.use_local_config = parse_bool_flag("use-local-config", inline_value)?;
                opts.visited.insert(name.to_string());
            }
            "report-dir" => {
                opts.report_dir = take_value("report-dir", inline_value, &args, &mut index)?;
                opts.visited.insert(name.to_string());
            }
            "dry-run" => {
                opts.dry_run = Some(parse_bool_flag("dry-run", inline_value)?);
                opts.visited.insert(name.to_string());
            }
            "delete-empty-dirs" => {
                opts.delete_empty_directories =
                    Some(parse_bool_flag("delete-empty-dirs", inline_value)?);
                opts.visited.insert(name.to_string());
            }
            "max-delete-ratio" => {
                let value = take_value("max-delete-ratio", inline_value, &args, &mut index)?;
                opts.max_delete_ratio = Some(parse_ratio(&value)?);
                opts.visited.insert(name.to_string());
            }
            "root" => {
                let value = take_value("root", inline_value, &args, &mut index)?;
                opts.roots.push(parse_root_flag(&value)?);
                opts.visited.insert(name.to_string());
            }
            _ => {
                return Err(ConfigError::Message(format!(
                    "flag provided but not defined: -{name}"
                )));
            }
        }

        index += 1;
    }

    Ok(opts)
}

fn take_value(
    name: &str,
    inline_value: Option<String>,
    args: &[String],
    index: &mut usize,
) -> Result<String, ConfigError> {
    if let Some(value) = inline_value {
        return Ok(value);
    }
    let next = *index + 1;
    if next >= args.len() {
        return Err(ConfigError::Message(format!(
            "flag needs an argument: -{name}"
        )));
    }
    *index = next;
    Ok(args[next].clone())
}

fn parse_bool_flag(name: &str, inline_value: Option<String>) -> Result<bool, ConfigError> {
    match inline_value {
        None => Ok(true),
        Some(value) => match value.as_str() {
            "1" | "t" | "T" | "true" | "TRUE" | "True" => Ok(true),
            "0" | "f" | "F" | "false" | "FALSE" | "False" => Ok(false),
            _ => Err(ConfigError::Message(format!(
                "invalid boolean value {value:?} for -{name}"
            ))),
        },
    }
}

fn parse_ratio(value: &str) -> Result<f64, ConfigError> {
    let ratio = value.parse::<f64>().map_err(|err| {
        ConfigError::Message(format!("invalid -max-delete-ratio value {value:?}: {err}"))
    })?;
    if !(0.0..=1.0).contains(&ratio) {
        return Err(ConfigError::Message(format!(
            "-max-delete-ratio must be between 0 and 1, got {ratio}"
        )));
    }
    Ok(ratio)
}

fn parse_root_flag(value: &str) -> Result<RootConfig, ConfigError> {
    let parts: Vec<&str> = value.splitn(3, ':').collect();
    match parts.as_slice() {
        [path] => Ok(RootConfig {
            path: path.to_string(),
            ..RootConfig::default()
        }),
        [kind, path] => Ok(RootConfig {
            kind: kind.to_string(),
            path: path.to_string(),
            ..RootConfig::default()
        }),
        [kind, mode, path] => Ok(RootConfig {
            kind: kind.to_string(),
            mode: mode.to_string(),
            path: path.to_string(),
        }),
        _ => Err(ConfigError::Message(format!(
            "invalid -root value {value:?}"
        ))),
    }
}

fn read_config(path: impl AsRef<Path>) -> Result<Config, ConfigError> {
    let path = path.as_ref();
    let data = fs::read(path)?;
    serde_json::from_slice(&data).map_err(|err| {
        ConfigError::Message(format!(
            "failed to parse config {:?}: {err}",
            path.display()
        ))
    })
}

fn apply_cli_overrides(cfg: &mut Config, opts: &CliOptions, source: &mut SourceInfo) {
    if opts.visited.contains("report-dir") {
        cfg.report_dir = opts.report_dir.clone();
        source.cli_overrides.push("ReportDir".to_string());
    }
    if opts.visited.contains("dry-run") {
        cfg.dry_run = opts.dry_run.unwrap_or(true);
        source.cli_overrides.push("DryRun".to_string());
    }
    if opts.visited.contains("delete-empty-dirs") {
        cfg.delete_empty_directories = opts.delete_empty_directories.unwrap_or(true);
        source
            .cli_overrides
            .push("DeleteEmptyDirectories".to_string());
    }
    if opts.visited.contains("max-delete-ratio") {
        cfg.max_delete_ratio = opts.max_delete_ratio;
        source.cli_overrides.push("MaxDeleteRatio".to_string());
    }
    if opts.visited.contains("root") {
        cfg.roots = opts.roots.clone();
        source.cli_overrides.push("Roots".to_string());
    }
}

pub fn usage() -> &'static str {
    r#"Usage:
  ck3-pruner -config config/prune-rules.json
  ck3-pruner -config config/prune-rules.json -dry-run
  ck3-pruner -config config/prune-rules.json -report-dir /reports/update

Key flags:
  -config <path>             JSON config path
  -use-local-config          Read ./config.json
  -report-dir <path>         Override ReportDir
  -dry-run[=true|false]      Plan only when true
  -delete-empty-dirs[=bool]  Remove empty directories after pruning
  -max-delete-ratio <0..1>   Abort real deletes above this file-count ratio
  -root <path>               Override Roots with one root
  -root <kind:path>          Override Roots with one typed root
  -root <kind:mode:path>     mode is single or workshop_collection
"#
}

fn is_false(value: &bool) -> bool {
    !*value
}

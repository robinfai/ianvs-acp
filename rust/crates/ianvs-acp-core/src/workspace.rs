use std::path::{Component, Path, PathBuf};

use thiserror::Error;

/// Failures while resolving a workspace trust boundary.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum WorkspaceError {
    #[error("workspace path must be absolute: {0}")]
    RelativePath(String),
    #[error("workspace path does not exist or cannot be resolved: {path}: {message}")]
    CannotResolve { path: String, message: String },
    #[error("path escapes the configured workspace roots: {0}")]
    OutsideWorkspace(String),
    #[error("workspace identity changed before execution: {0}")]
    IdentityChanged(String),
}

/// Canonical workspace roots used by filesystem, terminal, and task execution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceScope {
    cwd: PathBuf,
    roots: Vec<PathBuf>,
}

impl WorkspaceScope {
    /// Resolve all roots once and reject relative or missing roots.
    pub fn new(
        cwd: impl AsRef<Path>,
        additional_roots: impl IntoIterator<Item = impl AsRef<Path>>,
    ) -> Result<Self, WorkspaceError> {
        let cwd = canonical_root(cwd.as_ref())?;
        let mut roots = vec![cwd.clone()];
        for root in additional_roots {
            let canonical = canonical_root(root.as_ref())?;
            if !roots.contains(&canonical) {
                roots.push(canonical);
            }
        }
        Ok(Self { cwd, roots })
    }

    #[must_use]
    pub fn cwd(&self) -> &Path {
        &self.cwd
    }

    #[must_use]
    pub fn roots(&self) -> &[PathBuf] {
        &self.roots
    }

    /// Resolve an existing path and prove it is beneath an allowed root.
    pub fn resolve_existing(&self, path: impl AsRef<Path>) -> Result<PathBuf, WorkspaceError> {
        let candidate = self.absolute_candidate(path.as_ref())?;
        let canonical =
            candidate
                .canonicalize()
                .map_err(|error| WorkspaceError::CannotResolve {
                    path: candidate.display().to_string(),
                    message: error.to_string(),
                })?;
        self.ensure_allowed(canonical)
    }

    /// Resolve a path that may not exist yet. The nearest existing ancestor is
    /// canonicalized, preventing a pre-existing symlink from escaping the roots.
    /// The caller must still use an atomic/open-at style write to close TOCTOU.
    pub fn resolve_for_creation(&self, path: impl AsRef<Path>) -> Result<PathBuf, WorkspaceError> {
        let candidate = self.absolute_candidate(path.as_ref())?;
        let mut ancestor = candidate.as_path();
        let mut suffix = Vec::new();
        while !ancestor.exists() {
            let name = ancestor
                .file_name()
                .ok_or_else(|| WorkspaceError::CannotResolve {
                    path: candidate.display().to_string(),
                    message: "no existing ancestor".to_string(),
                })?;
            suffix.push(name.to_os_string());
            ancestor = ancestor
                .parent()
                .ok_or_else(|| WorkspaceError::CannotResolve {
                    path: candidate.display().to_string(),
                    message: "no existing ancestor".to_string(),
                })?;
        }
        let mut canonical =
            ancestor
                .canonicalize()
                .map_err(|error| WorkspaceError::CannotResolve {
                    path: ancestor.display().to_string(),
                    message: error.to_string(),
                })?;
        for component in suffix.into_iter().rev() {
            canonical.push(component);
        }
        self.ensure_allowed(canonical)
    }

    fn absolute_candidate(&self, path: &Path) -> Result<PathBuf, WorkspaceError> {
        let joined = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.cwd.join(path)
        };
        lexical_normalize(&joined)
            .ok_or_else(|| WorkspaceError::OutsideWorkspace(path.display().to_string()))
    }

    fn ensure_allowed(&self, path: PathBuf) -> Result<PathBuf, WorkspaceError> {
        if self.roots.iter().any(|root| path.starts_with(root)) {
            Ok(path)
        } else {
            Err(WorkspaceError::OutsideWorkspace(path.display().to_string()))
        }
    }
}

fn canonical_root(path: &Path) -> Result<PathBuf, WorkspaceError> {
    if !path.is_absolute() {
        return Err(WorkspaceError::RelativePath(path.display().to_string()));
    }
    path.canonicalize()
        .map_err(|error| WorkspaceError::CannotResolve {
            path: path.display().to_string(),
            message: error.to_string(),
        })
}

/// Normalize a persisted workspace identity without requiring the final path
/// to exist. Existing ancestors are canonicalized so a pre-existing symlink
/// cannot be smuggled into durable task state.
pub(crate) fn normalize_workspace_identity(path: &Path) -> Result<PathBuf, WorkspaceError> {
    if !path.is_absolute() {
        return Err(WorkspaceError::RelativePath(path.display().to_string()));
    }
    let candidate = lexical_normalize(path)
        .ok_or_else(|| WorkspaceError::OutsideWorkspace(path.display().to_string()))?;
    if candidate.exists() {
        return canonical_root(&candidate);
    }
    let mut ancestor = candidate.as_path();
    let mut suffix = Vec::new();
    while !ancestor.exists() {
        let name = ancestor
            .file_name()
            .ok_or_else(|| WorkspaceError::CannotResolve {
                path: candidate.display().to_string(),
                message: "no existing ancestor".to_string(),
            })?;
        suffix.push(name.to_os_string());
        ancestor = ancestor
            .parent()
            .ok_or_else(|| WorkspaceError::CannotResolve {
                path: candidate.display().to_string(),
                message: "no existing ancestor".to_string(),
            })?;
    }
    let mut normalized = canonical_root(ancestor)?;
    for component in suffix.into_iter().rev() {
        normalized.push(component);
    }
    Ok(normalized)
}

fn lexical_normalize(path: &Path) -> Option<PathBuf> {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => result.push(prefix.as_os_str()),
            Component::RootDir => result.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !result.pop() {
                    return None;
                }
            }
            Component::Normal(part) => result.push(part),
        }
    }
    Some(result)
}

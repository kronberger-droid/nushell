use nu_protocol::{ShellError, Span, engine::Stack, shell_error::io::IoError};

/// RAII guard for crossterm raw mode: [`acquire`](Self::acquire) checks
/// [`Stack::require_stdin`] and enables raw mode; [`Drop`] restores the mode found on entry.
///
/// Crossterm keeps a single process-wide "termios before raw mode" slot, so a bare
/// `disable_raw_mode()` always restores cooked mode, even when an outer caller (reedline's
/// `read_line`, around a menu source or completer) still expects raw mode. The guard therefore
/// only disables raw mode if it was the one to enable it.
#[must_use = "raw mode is restored as soon as the guard is dropped"]
pub(crate) struct RawModeGuard {
    /// Raw mode was already on when the guard was created, so it is left on when dropped.
    was_raw: bool,
}

impl RawModeGuard {
    /// Enter raw mode, or error per [`Stack::require_stdin`]. `span` points at the offending
    /// call.
    pub(crate) fn acquire(stack: &Stack, span: Span) -> Result<Self, ShellError> {
        stack.require_stdin(span)?;
        Self::enter().map_err(|err| IoError::new(err, span, None).into())
    }

    /// Enter raw mode without the [`Stack::require_stdin`] check, for widgets that have no
    /// `Stack` at hand. The calling command must have checked the precondition itself.
    pub(crate) fn enter() -> std::io::Result<Self> {
        let was_raw = crossterm::terminal::is_raw_mode_enabled()?;
        crossterm::terminal::enable_raw_mode()?;
        Ok(Self { was_raw })
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if !self.was_raw {
            let _ = crossterm::terminal::disable_raw_mode();
        }
    }
}

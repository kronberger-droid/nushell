use std::path::Path;

use nu_protocol::{Config, HistoryConfig, HistoryFileFormat, ShellError, Value};
use nu_test_support::prelude::*;
use nu_test_support::tester::NuTester;

const IMPORT_THREE_HISTORY_RECORDS: &str = "[[command start_timestamp duration exit_status cwd]; ['echo one' (date now) 10ms 0 /tmp] ['echo two' (date now) 20ms 0 /tmp] ['echo three' (date now) 30ms 0 /tmp]] | history import";

trait NuTesterHistoryExt {
    fn with_history(self, config_home: impl AsRef<Path>, format: HistoryFileFormat) -> Self;
}

impl NuTesterHistoryExt for NuTester {
    fn with_history(mut self, config_home: impl AsRef<Path>, format: HistoryFileFormat) -> Self {
        let config_home = config_home.as_ref().to_path_buf();
        std::fs::create_dir_all(&config_home).unwrap();

        self.engine_state.config_dirs.config_home = config_home;
        self.engine_state.set_config(Config {
            history: HistoryConfig {
                file_format: format,
                ..Default::default()
            },
            ..Default::default()
        });
        self.engine_state.generate_nu_constant();
        self
    }
}

/// Runs `code` against a sqlite history holding `echo one`, `echo two` and `echo three`.
fn with_three_entries(name: &str, code: impl FnOnce(&mut NuTester) -> Result) -> Result {
    Playground::setup(name, |dirs, _| {
        let config_home = dirs.test().join("nushell").to_std_path_buf();
        let mut tester = test().with_history(config_home, HistoryFileFormat::Sqlite);
        let () = tester.run(IMPORT_THREE_HISTORY_RECORDS)?;
        code(&mut tester)
    })
}

#[test]
fn history_delete_by_positional_id() -> Result {
    with_three_entries("history_delete_by_positional_id", |tester| {
        let () = tester
            .run("history delete (history --long | where command == 'echo two' | get item_id.0)")?;

        tester
            .run("history | get command")
            .expect_value_eq(["echo one", "echo three"])
    })
}

#[test]
fn history_delete_piped_records() -> Result {
    with_three_entries("history_delete_piped_records", |tester| {
        let () = tester.run("history --long | where command =~ '^echo t' | history delete")?;

        tester
            .run("history | get command")
            .expect_value_eq(["echo one"])
    })
}

#[test]
fn history_delete_piped_ids() -> Result {
    with_three_entries("history_delete_piped_ids", |tester| {
        let () = tester.run("history --long | first 2 | get item_id | history delete")?;

        tester
            .run("history | get command")
            .expect_value_eq(["echo three"])
    })
}

#[test]
fn history_delete_piped_lazy_history() -> Result {
    with_three_entries("history_delete_piped_lazy_history", |tester| {
        // `history --long` is a lazy SQLiteQueryBuilder, not a table.
        let () = tester.run("history --long | history delete")?;

        tester.run("history | length").expect_value_eq(0)
    })
}

#[test]
fn history_delete_ignores_duplicate_ids() -> Result {
    with_three_entries("history_delete_ignores_duplicate_ids", |tester| {
        let () = tester
            .run("let id = history --long | first | get item_id; [$id $id] | history delete $id")?;

        tester
            .run("history | get command")
            .expect_value_eq(["echo two", "echo three"])
    })
}

#[test]
fn history_delete_empty_input_deletes_nothing() -> Result {
    with_three_entries("history_delete_empty_input_deletes_nothing", |tester| {
        let () = tester.run("[] | history delete")?;
        let () = tester.run("null | history delete")?;

        tester.run("history | length").expect_value_eq(3)
    })
}

#[test]
fn history_delete_without_id_errors() -> Result {
    with_three_entries("history_delete_without_id_errors", |tester| {
        let err = tester.run::<Value>("history delete").expect_shell_error()?;
        assert!(
            matches!(err, ShellError::MissingParameter { .. }),
            "{err:?}"
        );
        Ok(())
    })
}

#[test]
fn history_delete_skips_unknown_ids() -> Result {
    with_three_entries("history_delete_skips_unknown_ids", |tester| {
        // The unknown id sorts first, so the known one after it must still be deleted.
        let () = tester.run(
            "history --long | where command == 'echo two' | get item_id | append 0 | history delete",
        )?;

        tester
            .run("history | get command")
            .expect_value_eq(["echo one", "echo three"])
    })
}

#[test]
fn history_delete_record_without_item_id_errors() -> Result {
    with_three_entries("history_delete_record_without_item_id_errors", |tester| {
        let err = tester
            .run::<Value>("{command: 'echo one'} | history delete")
            .expect_shell_error()?;
        assert!(matches!(err, ShellError::CantFindColumn { .. }), "{err:?}");
        Ok(())
    })
}

#[test]
fn history_delete_plaintext_history_errors() -> Result {
    Playground::setup("history_delete_plaintext_history_errors", |dirs, _| {
        let config_home = dirs.test().join("nushell").to_std_path_buf();
        let mut tester = test().with_history(config_home, HistoryFileFormat::Plaintext);

        let err = tester
            .run::<Value>("history delete 1")
            .expect_shell_error()?;
        assert!(matches!(err, ShellError::Generic(_)), "{err:?}");
        Ok(())
    })
}

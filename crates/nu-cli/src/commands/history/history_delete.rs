use super::fields;
use nu_engine::command_prelude::*;
use nu_protocol::{HistoryFileFormat, shell_error::generic::GenericError};
use reedline::{History as ReedlineHistory, HistoryItemId, SqliteBackedHistory};

#[derive(Clone)]
pub struct HistoryDelete;

impl Command for HistoryDelete {
    fn name(&self) -> &str {
        "history delete"
    }

    fn description(&self) -> &str {
        "Delete entries from the history."
    }

    fn extra_description(&self) -> &str {
        "Takes item ids as an argument or from the pipeline, either as ints or as records with an `item_id` column like the ones `history --long` returns. Ids that are not in the history are skipped. Only works with the sqlite history."
    }

    fn signature(&self) -> nu_protocol::Signature {
        Signature::build("history delete")
            .input_output_types(vec![
                (Type::Nothing, Type::Nothing),
                (Type::Int, Type::Nothing),
                (Type::list(Type::Int), Type::Nothing),
                (Type::record(), Type::Nothing),
                (Type::table(), Type::Nothing),
                (Type::Custom("SQLiteQueryBuilder".into()), Type::Nothing),
            ])
            .optional("id", SyntaxShape::Int, "Id of the history item to delete.")
            .category(Category::History)
    }

    fn examples(&self) -> Vec<Example<'_>> {
        vec![
            Example {
                example: "history delete 123",
                description: "Delete the history item with id 123",
                result: None,
            },
            Example {
                example: "history --long | where command =~ '^ouch ' | history delete",
                description: "Delete every command starting with `ouch`",
                result: None,
            },
            Example {
                example: "history --long | input list --multi --fuzzy --display command | history delete",
                description: "Pick the entries to delete with a fuzzy finder",
                result: None,
            },
        ]
    }

    fn run(
        &self,
        engine_state: &EngineState,
        stack: &mut Stack,
        call: &Call,
        input: PipelineData,
    ) -> Result<PipelineData, ShellError> {
        let head = call.head;

        let Some(history) = engine_state.history_config() else {
            return Ok(PipelineData::empty());
        };
        // Plaintext history has no stable ids, so reedline can't delete single entries from it.
        if history.file_format != HistoryFileFormat::Sqlite {
            return Err(ShellError::Generic(
                GenericError::new(
                    "Cannot delete history items",
                    "deleting entries needs the sqlite history",
                    head,
                )
                .with_help("Set `$env.config.history.file_format = \"sqlite\"`"),
            ));
        }
        let Some(history_path) = history.file_path(&engine_state.config_dirs.config_home) else {
            return Err(ShellError::ConfigDirNotFound { span: head });
        };

        let id: Option<Spanned<i64>> = call.opt(engine_state, stack, 0)?;
        let has_input = !matches!(input, PipelineData::Empty);
        if id.is_none() && !has_input {
            return Err(ShellError::MissingParameter {
                param_name: "id".into(),
                span: head,
            });
        }

        // Collect every id before touching the database: the input may still be reading from it.
        let mut ids: Vec<Spanned<i64>> = id.into_iter().collect();
        if has_input {
            for value in input {
                ids.extend(item_id(value, head)?);
            }
        }
        ids.sort_by_key(|id| id.item);
        ids.dedup_by_key(|id| id.item);

        if ids.is_empty() {
            return Ok(PipelineData::empty());
        }

        let mut history =
            SqliteBackedHistory::with_file(history_path, None, None).map_err(|e| {
                ShellError::Generic(GenericError::new(
                    "Could not open history",
                    e.to_string(),
                    head,
                ))
            })?;
        for id in ids {
            let item_id = HistoryItemId::new(id.item);
            // reedline reports a missing id like any other database error, so a failed delete
            // only counts when the item is still there. Missing ids are skipped.
            if let Err(e) = history.delete(item_id)
                && history.load(item_id).is_ok()
            {
                return Err(ShellError::IncorrectValue {
                    msg: format!("Could not delete history item of id {}: {e}", id.item),
                    val_span: id.span,
                    call_span: head,
                });
            }
        }

        Ok(PipelineData::empty())
    }
}

/// Reads a history item id from a pipeline value: an int, or a record's `item_id` column.
/// `null` yields no id, so an empty selection (e.g. from `input list`) deletes nothing.
fn item_id(value: Value, head: Span) -> Result<Option<Spanned<i64>>, ShellError> {
    let span = value.span();
    match value {
        Value::Int { val, .. } => Ok(Some(val.into_spanned(span))),
        Value::Record { val, .. } => match val.get(fields::ITEM_ID) {
            Some(id) => Ok(Some(id.as_int()?.into_spanned(id.span()))),
            None => Err(ShellError::CantFindColumn {
                col_name: fields::ITEM_ID.into(),
                span: Some(head),
                src_span: span,
            }),
        },
        Value::Nothing { .. } => Ok(None),
        Value::Error { error, .. } => Err(*error),
        other => Err(ShellError::OnlySupportsThisInputType {
            exp_input_type: "int, or record with an item_id column".into(),
            wrong_type: other.get_type().to_string(),
            dst_span: head,
            src_span: span,
        }),
    }
}

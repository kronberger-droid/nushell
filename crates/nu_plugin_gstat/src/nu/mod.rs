use crate::{GStat, TagMode};
use nu_plugin::{EngineInterface, EvaluatedCall, Plugin, PluginCommand, SimplePluginCommand};
use nu_protocol::{Category, LabeledError, Signature, Spanned, SyntaxShape, Value};

pub struct GStatPlugin;

impl Plugin for GStatPlugin {
    fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").into()
    }

    fn commands(&self) -> Vec<Box<dyn PluginCommand<Plugin = Self>>> {
        vec![Box::new(GStat)]
    }
}

impl SimplePluginCommand for GStat {
    type Plugin = GStatPlugin;

    fn name(&self) -> &str {
        "gstat"
    }

    fn description(&self) -> &str {
        "Get the git status of a repo"
    }

    fn extra_description(&self) -> &str {
        "Every count is -1 outside a git repository. Inside one, the status counts (idx_*, wt_*, \
ignored and conflicts) are -1 when the status can't be read, for example with a split or sparse \
index or in a bare repository. wt_renamed counts unstaged renames, a deleted file paired with a \
similar untracked file, which then don't count as wt_deleted or wt_untracked; a renamed file \
that was also edited counts in wt_modified too. An ignored directory counts once in ignored."
    }

    fn signature(&self) -> Signature {
        Signature::build(PluginCommand::name(self))
            .switch("no-tag", "Disable git tag resolving.", None)
            .switch(
                "exact-tag",
                "Only report a tag that is on HEAD, without searching for the nearest one.",
                None,
            )
            .optional("path", SyntaxShape::Filepath, "Path to repo.")
            .category(Category::Custom("prompt".to_string()))
    }

    fn run(
        &self,
        _plugin: &GStatPlugin,
        engine: &EngineInterface,
        call: &EvaluatedCall,
        input: &Value,
    ) -> Result<Value, LabeledError> {
        let repo_path: Option<Spanned<String>> = call.opt(0)?;
        // eprintln!("input value: {:#?}", &input);
        let current_dir = engine.get_current_dir()?;
        let tags = if call.has_flag("no-tag")? {
            TagMode::Skip
        } else if call.has_flag("exact-tag")? {
            TagMode::Exact
        } else {
            TagMode::Nearest
        };

        self.gstat(input, &current_dir, repo_path, tags, call.head)
    }
}

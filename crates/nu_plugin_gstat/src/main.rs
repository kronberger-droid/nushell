use nu_plugin::{MsgPackSerializer, serve_plugin};
use nu_plugin_gstat::GStatPlugin;

fn main() {
    // libgit2 hashes every object it reads to check it against its name, which git itself only
    // does in `git fsck`. A status reads objects to report on them, never to trust them with
    // anything, and on a large repository the check was about a seventh of a call.
    git2::opts::strict_hash_verification(false);

    serve_plugin(&GStatPlugin, MsgPackSerializer {})
}

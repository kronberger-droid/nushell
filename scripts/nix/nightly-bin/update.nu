#!/usr/bin/env nu

# Write the nightly.json that ./flake.nix builds from: the tag of a nightly
# release and, per Nix system, the URL and sha256 of its archive.
#
# Meant to run in the nightly workflow once the release assets are uploaded.
# Reads GITHUB_TOKEN from the environment when it is set, to stay clear of the
# rate limit for anonymous API requests.

# Nix system to the Rust target of the archive it gets. Linux takes the glibc
# builds, which package.nix patches to run from the Nix store.
const TARGETS = {
    x86_64-linux: x86_64-unknown-linux-gnu
    aarch64-linux: aarch64-unknown-linux-gnu
    armv7l-linux: armv7-unknown-linux-gnueabihf
    riscv64-linux: riscv64gc-unknown-linux-gnu
    loongarch64-linux: loongarch64-unknown-linux-gnu
    x86_64-darwin: x86_64-apple-darwin
    aarch64-darwin: aarch64-apple-darwin
}

# The sha256 of a release asset, as lowercase hex.
#
# GitHub reports a digest for assets uploaded since mid 2025. Anything older is
# downloaded and hashed.
def asset-sha256 []: record -> string {
    let asset = $in
    match ($asset.digest? | default '') {
        $d if ($d starts-with 'sha256:') => ($d | str replace 'sha256:' '')
        _ => (http get --raw $asset.browser_download_url | hash sha256)
    }
}

# Generate nightly.json for a nightly release.
def main [
    --tag: string # Release tag, e.g. 0.117.1-nightly.5+4e65e63 (default: the latest nightly)
    --repo: string = 'nushell/nightly' # Repository the releases are in
    --out: path # File to write (default: nightly.json next to this script)
] {
    let out = $out | default ($env.FILE_PWD | path join nightly.json)
    let headers = match $env.GITHUB_TOKEN? {
        null | '' => []
        $token => [Authorization $'Bearer ($token)']
    }

    # Listed and filtered instead of fetched by tag: the tags contain a `+`,
    # and only a handful of nightlies exist at a time.
    let releases = http get --headers $headers $'https://api.github.com/repos/($repo)/releases'
        | where tag_name =~ nightly
        | sort-by --reverse created_at
    let release = if $tag == null { $releases | get 0? } else {
        $releases | where tag_name == $tag | get 0?
    }
    if $release == null {
        error make { msg: $'no nightly release ($tag | default "at all") in ($repo)' }
    }

    let systems = $TARGETS
        | transpose system target
        | each {|entry|
            let archive = $'($entry.target).tar.gz'
            let asset = $release.assets | where name ends-with $archive | get 0?
            if $asset == null {
                print --stderr $'no archive for ($entry.target), leaving out ($entry.system)'
                return
            }
            { system: $entry.system, url: $asset.browser_download_url, sha256: ($asset | asset-sha256) }
        }
        | reduce --fold {} {|entry, acc| $acc | insert $entry.system ($entry | reject system) }

    if ($systems | is-empty) {
        error make { msg: $'release ($release.tag_name) has none of the expected archives' }
    }

    {
        tag: $release.tag_name
        # The tag without the commit, which is what `version` reports.
        version: ($release.tag_name | split row '+' | first)
        systems: $systems
    } | to json | $in + "\n" | save --force $out

    print $'wrote ($out) for ($release.tag_name): ($systems | columns | str join ", ")'
}

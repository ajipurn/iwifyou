# Shared build environment for the dependency-free local package.
export CLANG_MODULE_CACHE_PATH="${PWD}/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p .build/cache .build/configuration .build/security

swiftpm() {
    # Native backend works with the installed CLT; nested sandbox-exec is not
    # available inside Codex. The package has no third-party build plugins.
    swift "$@" --disable-sandbox --build-system native \
        --cache-path "$PWD/.build/cache" \
        --config-path "$PWD/.build/configuration" \
        --security-path "$PWD/.build/security"
}
